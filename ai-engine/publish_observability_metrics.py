#!/usr/bin/env python3
import argparse
import csv
import json
import math
import subprocess
import sys
import time
import urllib.request
from pathlib import Path


DECISIONS = ["PROMOTE", "PAUSE", "ABORT", "NOT_AVAILABLE"]
ACTIONS = [
    "KEEP_GREEN",
    "ROLLBACK_REQUIRED",
    "ROLLED_BACK_TO_BLUE",
    "NOT_RUN",
    "NOT_AVAILABLE",
]
PHASES = {
    "blue": {
        "summary": Path("results/blue-baseline/summary.json"),
        "jtl": Path("results/blue-baseline/blue-baseline.jtl"),
    },
    "green": {
        "summary": Path("results/green-validation/summary.json"),
        "jtl": Path("results/green-validation/green-validation.jtl"),
    },
    "post_promotion": {
        "summary": Path("results/post-promotion/summary.json"),
        "jtl": Path("results/post-promotion/post-promotion.jtl"),
    },
}


def load_json(path: Path):
    if not path.exists():
        return None
    with path.open("r", encoding="utf-8-sig") as f:
        return json.load(f)


def first_value(obj, *keys, default=None):
    if not isinstance(obj, dict):
        return default
    for key in keys:
        if key in obj and obj[key] is not None:
            return obj[key]
    return default


def as_float(value, default=0.0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def as_int(value, default=0):
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return default


def prom_escape(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def metric_line(name, value, labels=None):
    labels = labels or {}
    label_text = ""
    if labels:
        label_text = "{" + ",".join(
            f'{k}="{prom_escape(v)}"' for k, v in sorted(labels.items())
        ) + "}"
    if isinstance(value, bool):
        value = 1 if value else 0
    if isinstance(value, float):
        if math.isnan(value) or math.isinf(value):
            value = 0
        value = f"{value:.6f}".rstrip("0").rstrip(".")
        if value == "-0":
            value = "0"
    return f"{name}{label_text} {value}"


def metric_help(lines, name, help_text, metric_type="gauge"):
    lines.append(f"# HELP {name} {help_text}")
    lines.append(f"# TYPE {name} {metric_type}")


def jtl_throughput(jtl_path: Path, total_requests: int):
    if not jtl_path.exists() or total_requests <= 0:
        return 0.0

    timestamps = []
    try:
        with jtl_path.open("r", encoding="utf-8-sig", newline="") as f:
            reader = csv.DictReader(f)
            for row in reader:
                raw = row.get("timeStamp")
                if raw is None:
                    continue
                try:
                    timestamps.append(float(raw))
                except ValueError:
                    continue
    except Exception:
        return 0.0

    if len(timestamps) < 2:
        return 0.0

    elapsed_seconds = (max(timestamps) - min(timestamps)) / 1000.0
    if elapsed_seconds <= 0:
        return 0.0
    return total_requests / elapsed_seconds


def parse_jmeter_summary(summary, jtl_path):
    if not summary:
        return None

    total = as_int(first_value(summary, "totalRequests", "total", "samples"))
    success = as_int(
        first_value(summary, "successfulRequests", "success", "successful"),
        default=max(total - as_int(first_value(summary, "failedRequests", "failed", "errors")), 0),
    )
    failed = as_int(
        first_value(summary, "failedRequests", "failed", "errors"),
        default=max(total - success, 0),
    )
    error_rate = as_float(
        first_value(summary, "errorRatePct", "errorRatePercent", "errorRate"),
        default=(failed / total * 100.0) if total else 0.0,
    )
    avg = as_float(
        first_value(summary, "averageResponseMs", "averageMs", "avgResponseMs", "average")
    )
    p95 = as_float(
        first_value(summary, "p95ResponseMs", "p95Ms", "p95")
    )
    min_ms = as_float(first_value(summary, "minResponseMs", "minMs", "min"))
    max_ms = as_float(first_value(summary, "maxResponseMs", "maxMs", "max"))
    throughput = as_float(
        first_value(summary, "throughputRps", "requestsPerSecond", "throughput"),
        default=0.0,
    )
    if throughput <= 0:
        throughput = jtl_throughput(jtl_path, total)

    concurrent_users = as_int(
        first_value(summary, "concurrentUsers", "threads", "users", default=0)
    )

    return {
        "total": total,
        "success": success,
        "failed": failed,
        "error_rate": error_rate,
        "avg": avg,
        "p95": p95,
        "min": min_ms,
        "max": max_ms,
        "throughput": throughput,
        "concurrent_users": concurrent_users,
    }


def run_kubectl_json(args):
    cmd = ["kubectl"] + args + ["-o", "json"]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(
            f"Command failed: {' '.join(cmd)}\n{result.stderr.strip()}"
        )
    return json.loads(result.stdout)


def get_health(url):
    try:
        with urllib.request.urlopen(url, timeout=3) as response:
            return json.loads(response.read().decode("utf-8"))
    except Exception:
        return {"status": "UNKNOWN", "version": "unknown"}


def env_from_version(version):
    version = (version or "").lower()
    if version.startswith("v1") or "blue" in version:
        return "blue"
    if version.startswith("v2") or "green" in version:
        return "green"
    return "unknown"


def collect_cluster_state(namespace, rollout_name):
    rollout = run_kubectl_json(
        ["get", "rollout", rollout_name, "-n", namespace]
    )
    pods = run_kubectl_json(["get", "pods", "-n", namespace])

    active_health = get_health("http://localhost:8081/health")
    preview_health = get_health("http://localhost:8082/health")

    active_env = env_from_version(active_health.get("version"))
    preview_env = env_from_version(preview_health.get("version"))

    pod_state = {
        "blue": {"pods": 0, "ready": 0, "restarts": 0},
        "green": {"pods": 0, "ready": 0, "restarts": 0},
    }

    for item in pods.get("items", []):
        containers = item.get("spec", {}).get("containers", [])
        version = ""
        if containers:
            for env in containers[0].get("env", []) or []:
                if env.get("name") == "APP_VERSION":
                    version = env.get("value", "")
                    break

        environment = env_from_version(version)
        if environment not in pod_state:
            continue

        pod_state[environment]["pods"] += 1
        conditions = item.get("status", {}).get("conditions", []) or []
        if any(
            c.get("type") == "Ready" and c.get("status") == "True"
            for c in conditions
        ):
            pod_state[environment]["ready"] += 1

        for cs in item.get("status", {}).get("containerStatuses", []) or []:
            pod_state[environment]["restarts"] += as_int(cs.get("restartCount"))

    phase = rollout.get("status", {}).get("phase", "Unknown")
    stable_rs = rollout.get("status", {}).get("stableRS", "unknown")
    current_hash = rollout.get("status", {}).get("currentPodHash", "unknown")

    return {
        "active_env": active_env,
        "preview_env": preview_env,
        "active_version": active_health.get("version", "unknown"),
        "preview_version": preview_health.get("version", "unknown"),
        "active_health": active_health.get("status", "UNKNOWN"),
        "preview_health": preview_health.get("status", "UNKNOWN"),
        "phase": phase,
        "stable_rs": stable_rs,
        "current_hash": current_hash,
        "pods": pod_state,
    }


def parse_comparison(comparison):
    if not comparison:
        return None

    regressions = comparison.get("regressions", {}) or {}
    technical = str(comparison.get("technicalGate", "NOT_AVAILABLE")).upper()

    return {
        "technical_pass": 1 if technical == "PASS" else 0,
        "error_delta": as_float(
            first_value(regressions, "errorRateDeltaPoints", "errorDeltaPoints")
        ),
        "avg_regression": as_float(
            first_value(
                regressions,
                "averageResponseRegressionPct",
                "averageLatencyRegressionPct",
            )
        ),
        "p95_regression": as_float(
            first_value(regressions, "p95RegressionPct", "p95LatencyRegressionPct")
        ),
    }


def parse_decision(decision):
    if not decision:
        return {
            "base": 0.0,
            "adjustment": 0.0,
            "final": 0.0,
            "confidence": 0.0,
            "decision": "NOT_AVAILABLE",
            "model": "not_available",
            "ai_available": 0,
        }

    final_decision = str(
        first_value(decision, "finalDecision", "decision", default="NOT_AVAILABLE")
    ).upper()

    model = str(
        first_value(decision, "model", "aiModel", default="qwen3:4b-instruct")
    )

    confidence = as_float(
        first_value(
            decision,
            "aiConfidence",
            "confidence",
            "confidencePercent",
            default=0.0,
        )
    )

    ai_available_raw = first_value(
        decision, "aiAvailable", default=True
    )
    ai_available = 1 if bool(ai_available_raw) else 0

    return {
        "base": as_float(first_value(decision, "baseRiskScore", "baseRisk", default=0)),
        "adjustment": as_float(
            first_value(decision, "aiRiskAdjustment", "riskAdjustment", default=0)
        ),
        "final": as_float(
            first_value(decision, "finalRiskScore", "riskScore", default=0)
        ),
        "confidence": confidence,
        "decision": final_decision if final_decision in DECISIONS else "NOT_AVAILABLE",
        "model": model,
        "ai_available": ai_available,
    }


def get_action(project_root):
    rollback = load_json(project_root / "results/rollback/rollback-state.json")
    if rollback and rollback.get("rollbackCompleted") is True:
        return "ROLLED_BACK_TO_BLUE"

    post_state = load_json(project_root / "results/post-promotion/final-state.json")
    if post_state:
        action = str(post_state.get("finalAction", "NOT_AVAILABLE")).upper()
        if action in ACTIONS:
            return action

    return "NOT_RUN"


def telemetry_env(telemetry, environment):
    if not telemetry or not isinstance(telemetry, dict):
        return None
    raw = telemetry.get(environment)
    if not isinstance(raw, dict):
        return None

    return {
        "ready": as_float(first_value(raw, "readyPods", "podsReady", "ready", default=0)),
        "expected": as_float(first_value(raw, "expectedPods", "expected", default=0)),
        "restarts": as_float(first_value(raw, "restarts", "restartCount", default=0)),
        "cpu_m": as_float(first_value(raw, "cpuMillicores", "cpuM", default=0)),
        "cpu_pct": as_float(
            first_value(raw, "cpuPercentOfLimit", "cpuPctOfLimit", "cpuPercent", default=0)
        ),
        "memory_mib": as_float(first_value(raw, "memoryMiB", "memoryMib", default=0)),
        "memory_pct": as_float(
            first_value(raw, "memoryPercentOfLimit", "memoryPctOfLimit", "memoryPercent", default=0)
        ),
    }


def build_metrics(project_root, namespace, rollout_name):
    lines = []

    # JMeter snapshots for every completed phase.
    metric_help(lines, "jmeter_total_requests", "Total JMeter requests in the completed validation phase.")
    metric_help(lines, "jmeter_successful_requests", "Successful JMeter requests in the completed validation phase.")
    metric_help(lines, "jmeter_failed_requests", "Failed JMeter requests in the completed validation phase.")
    metric_help(lines, "jmeter_error_rate_percent", "JMeter error rate percentage.")
    metric_help(lines, "jmeter_average_response_ms", "JMeter average response time in milliseconds.")
    metric_help(lines, "jmeter_p95_response_ms", "JMeter 95th percentile response time in milliseconds.")
    metric_help(lines, "jmeter_min_response_ms", "JMeter minimum response time in milliseconds.")
    metric_help(lines, "jmeter_max_response_ms", "JMeter maximum response time in milliseconds.")
    metric_help(lines, "jmeter_throughput_rps", "JMeter request throughput in requests per second.")
    metric_help(lines, "jmeter_concurrent_users", "Configured JMeter concurrent-user count for the validation phase.")

    for phase, paths in PHASES.items():
        summary = load_json(project_root / paths["summary"])
        parsed = parse_jmeter_summary(summary, project_root / paths["jtl"])
        if not parsed:
            continue
        labels = {"test_phase": phase}
        lines.append(metric_line("jmeter_total_requests", parsed["total"], labels))
        lines.append(metric_line("jmeter_successful_requests", parsed["success"], labels))
        lines.append(metric_line("jmeter_failed_requests", parsed["failed"], labels))
        lines.append(metric_line("jmeter_error_rate_percent", parsed["error_rate"], labels))
        lines.append(metric_line("jmeter_average_response_ms", parsed["avg"], labels))
        lines.append(metric_line("jmeter_p95_response_ms", parsed["p95"], labels))
        lines.append(metric_line("jmeter_min_response_ms", parsed["min"], labels))
        lines.append(metric_line("jmeter_max_response_ms", parsed["max"], labels))
        lines.append(metric_line("jmeter_throughput_rps", parsed["throughput"], labels))
        lines.append(metric_line("jmeter_concurrent_users", parsed["concurrent_users"], labels))

    # Technical gate / regression metrics.
    metric_help(lines, "ai_bluegreen_technical_gate", "Deterministic technical gate state where 1 is PASS and 0 is FAIL.")
    metric_help(lines, "ai_bluegreen_error_rate_delta_points", "Error rate delta in percentage points versus Blue baseline.")
    metric_help(lines, "ai_bluegreen_average_latency_regression_percent", "Average response-time regression percentage versus Blue baseline.")
    metric_help(lines, "ai_bluegreen_p95_latency_regression_percent", "P95 response-time regression percentage versus Blue baseline.")

    comparisons = {
        "pre_promotion": load_json(project_root / "results/green-validation/comparison.json"),
        "post_promotion": load_json(project_root / "results/post-promotion/comparison.json"),
    }
    for stage, comparison in comparisons.items():
        parsed = parse_comparison(comparison)
        if not parsed:
            continue
        labels = {"stage": stage}
        lines.append(metric_line("ai_bluegreen_technical_gate", parsed["technical_pass"], labels))
        lines.append(metric_line("ai_bluegreen_error_rate_delta_points", parsed["error_delta"], labels))
        lines.append(metric_line("ai_bluegreen_average_latency_regression_percent", parsed["avg_regression"], labels))
        lines.append(metric_line("ai_bluegreen_p95_latency_regression_percent", parsed["p95_regression"], labels))

    # AI decisions from both analysis stages.
    metric_help(lines, "ai_bluegreen_base_risk_score", "Deterministic deployment base risk score.")
    metric_help(lines, "ai_bluegreen_ai_risk_adjustment", "Bounded contextual AI risk adjustment.")
    metric_help(lines, "ai_bluegreen_final_risk_score", "Final deployment risk score after AI adjustment.")
    metric_help(lines, "ai_bluegreen_ai_confidence_percent", "AI contextual-analysis confidence percentage.")
    metric_help(lines, "ai_bluegreen_ai_available", "Whether contextual AI was available, where 1 is available.")
    metric_help(lines, "ai_bluegreen_decision_state", "One-hot deployment decision state.")
    metric_help(lines, "ai_bluegreen_model_info", "AI model information metric.")

    decisions = {
        "pre_promotion": load_json(project_root / "results/ai-analysis/decision.json"),
        "post_promotion": load_json(project_root / "results/post-promotion/decision.json"),
    }
    for stage, raw_decision in decisions.items():
        # Do not publish synthetic 0/100 AI values before that AI stage
        # has actually executed. Grafana will show no data until a real
        # decision file exists for the stage.
        if not raw_decision:
            continue

        parsed = parse_decision(raw_decision)
        stage_labels = {"stage": stage}
        lines.append(metric_line("ai_bluegreen_base_risk_score", parsed["base"], stage_labels))
        lines.append(metric_line("ai_bluegreen_ai_risk_adjustment", parsed["adjustment"], stage_labels))
        lines.append(metric_line("ai_bluegreen_final_risk_score", parsed["final"], stage_labels))
        lines.append(metric_line("ai_bluegreen_ai_confidence_percent", parsed["confidence"], stage_labels))
        lines.append(metric_line("ai_bluegreen_ai_available", parsed["ai_available"], stage_labels))
        lines.append(metric_line("ai_bluegreen_model_info", 1, {"stage": stage, "model": parsed["model"]}))
        for decision in DECISIONS:
            lines.append(
                metric_line(
                    "ai_bluegreen_decision_state",
                    1 if parsed["decision"] == decision else 0,
                    {"stage": stage, "decision": decision},
                )
            )

    # Snapshot telemetry used by the AI engine.
    metric_help(lines, "ai_bluegreen_snapshot_cpu_millicores", "CPU millicores observed in the AI telemetry snapshot.")
    metric_help(lines, "ai_bluegreen_snapshot_cpu_percent_of_limit", "CPU percentage of configured limit observed in the AI telemetry snapshot.")
    metric_help(lines, "ai_bluegreen_snapshot_memory_mib", "Memory MiB observed in the AI telemetry snapshot.")
    metric_help(lines, "ai_bluegreen_snapshot_memory_percent_of_limit", "Memory percentage of configured limit observed in the AI telemetry snapshot.")
    metric_help(lines, "ai_bluegreen_snapshot_restarts", "Container restarts observed in the AI telemetry snapshot.")
    metric_help(lines, "ai_bluegreen_snapshot_ready_pods", "Ready pods observed in the AI telemetry snapshot.")

    telemetry_by_stage = {
        "pre_promotion": load_json(project_root / "results/ai-analysis/telemetry.json"),
        "post_promotion": load_json(project_root / "results/post-promotion/telemetry.json"),
    }
    for stage, telemetry in telemetry_by_stage.items():
        for environment in ("blue", "green"):
            parsed = telemetry_env(telemetry, environment)
            if not parsed:
                continue
            labels = {"stage": stage, "environment": environment}
            lines.append(metric_line("ai_bluegreen_snapshot_cpu_millicores", parsed["cpu_m"], labels))
            lines.append(metric_line("ai_bluegreen_snapshot_cpu_percent_of_limit", parsed["cpu_pct"], labels))
            lines.append(metric_line("ai_bluegreen_snapshot_memory_mib", parsed["memory_mib"], labels))
            lines.append(metric_line("ai_bluegreen_snapshot_memory_percent_of_limit", parsed["memory_pct"], labels))
            lines.append(metric_line("ai_bluegreen_snapshot_restarts", parsed["restarts"], labels))
            lines.append(metric_line("ai_bluegreen_snapshot_ready_pods", parsed["ready"], labels))

    # Current live deployment state.
    state = collect_cluster_state(namespace, rollout_name)

    metric_help(lines, "ai_bluegreen_traffic_percent", "Current production traffic percentage by Blue-Green environment.")
    metric_help(lines, "ai_bluegreen_environment_state", "One-hot current environment role state for Active and Preview.")
    metric_help(lines, "ai_bluegreen_version_info", "Current Active and Preview application versions.")
    metric_help(lines, "ai_bluegreen_rollout_phase_info", "Current Argo Rollout phase.")
    metric_help(lines, "ai_bluegreen_rollout_healthy", "Whether the Argo Rollout phase is Healthy.")
    metric_help(lines, "ai_bluegreen_ready_pods", "Current ready application pods by environment.")
    metric_help(lines, "ai_bluegreen_pod_count", "Current application pod count by environment.")
    metric_help(lines, "ai_bluegreen_restart_count", "Current container restart count by environment.")

    for env in ("blue", "green"):
        traffic = 100 if state["active_env"] == env else 0
        lines.append(metric_line("ai_bluegreen_traffic_percent", traffic, {"environment": env}))

        for role, current_env in (
            ("active", state["active_env"]),
            ("preview", state["preview_env"]),
        ):
            lines.append(
                metric_line(
                    "ai_bluegreen_environment_state",
                    1 if current_env == env else 0,
                    {"role": role, "environment": env},
                )
            )

        lines.append(metric_line("ai_bluegreen_ready_pods", state["pods"][env]["ready"], {"environment": env}))
        lines.append(metric_line("ai_bluegreen_pod_count", state["pods"][env]["pods"], {"environment": env}))
        lines.append(metric_line("ai_bluegreen_restart_count", state["pods"][env]["restarts"], {"environment": env}))

    lines.append(
        metric_line(
            "ai_bluegreen_version_info",
            1,
            {
                "role": "active",
                "environment": state["active_env"],
                "version": state["active_version"],
                "health": state["active_health"],
            },
        )
    )
    lines.append(
        metric_line(
            "ai_bluegreen_version_info",
            1,
            {
                "role": "preview",
                "environment": state["preview_env"],
                "version": state["preview_version"],
                "health": state["preview_health"],
            },
        )
    )
    lines.append(
        metric_line(
            "ai_bluegreen_rollout_phase_info",
            1,
            {
                "phase": state["phase"],
                "stable_rs": state["stable_rs"],
                "current_hash": state["current_hash"],
            },
        )
    )
    lines.append(
        metric_line(
            "ai_bluegreen_rollout_healthy",
            1 if str(state["phase"]).lower() == "healthy" else 0,
        )
    )

    # Final deployment action.
    action = get_action(project_root)
    metric_help(lines, "ai_bluegreen_post_action_state", "One-hot final post-promotion action state.")
    for candidate in ACTIONS:
        lines.append(
            metric_line(
                "ai_bluegreen_post_action_state",
                1 if action == candidate else 0,
                {"action": candidate},
            )
        )

    metric_help(lines, "ai_bluegreen_observability_publish_timestamp_seconds", "Unix timestamp of the most recent observability metrics publication.")
    lines.append(metric_line("ai_bluegreen_observability_publish_timestamp_seconds", time.time()))

    # Return both the text and a concise state summary.
    payload = "\n".join(lines) + "\n"
    return payload, state, action


def push_metrics(pushgateway_url, job, payload):
    url = pushgateway_url.rstrip("/") + f"/metrics/job/{job}"
    request = urllib.request.Request(
        url,
        data=payload.encode("utf-8"),
        method="PUT",
        headers={"Content-Type": "text/plain; version=0.0.4; charset=utf-8"},
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        if response.status not in (200, 202):
            raise RuntimeError(f"Pushgateway returned HTTP {response.status}")


def main():
    parser = argparse.ArgumentParser(
        description="Publish AI Blue-Green JMeter, AI, and deployment state metrics to Prometheus Pushgateway."
    )
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--pushgateway-url", default="http://localhost:19091")
    parser.add_argument("--job", default="ai_bluegreen_intelligence")
    parser.add_argument("--namespace", default="ai-bluegreen")
    parser.add_argument("--rollout", default="ai-bluegreen-rollout")
    parser.add_argument("--output")
    args = parser.parse_args()

    project_root = Path(args.project_root).resolve()
    if not project_root.exists():
        print(f"[FAIL] Project root does not exist: {project_root}")
        return 1

    try:
        payload, state, action = build_metrics(
            project_root, args.namespace, args.rollout
        )

        if args.output:
            output = Path(args.output)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(payload, encoding="utf-8", newline="\n")

        push_metrics(args.pushgateway_url, args.job, payload)

        print("==========================================")
        print(" AI BLUE-GREEN OBSERVABILITY PUBLISHER")
        print("==========================================")
        print(f"Pushgateway     : {args.pushgateway_url}")
        print(f"Job             : {args.job}")
        print(f"Active env      : {state['active_env']}")
        print(f"Active version  : {state['active_version']}")
        print(f"Preview env     : {state['preview_env']}")
        print(f"Preview version : {state['preview_version']}")
        print(f"Rollout phase   : {state['phase']}")
        print(f"Final action    : {action}")
        print("")
        print("JMeter phases published:")
        for phase, paths in PHASES.items():
            summary = load_json(project_root / paths["summary"])
            parsed = parse_jmeter_summary(summary, project_root / paths["jtl"])
            if parsed:
                print(
                    f"- {phase}: requests={parsed['total']}, "
                    f"success={parsed['success']}, failed={parsed['failed']}, "
                    f"error={parsed['error_rate']:.3f}%, "
                    f"users={parsed['concurrent_users']}, "
                    f"avg={parsed['avg']:.2f}ms, p95={parsed['p95']:.2f}ms, "
                    f"throughput={parsed['throughput']:.2f} req/s"
                )
        print("")
        print("PUBLISH RESULT: PASS")
        return 0

    except Exception as exc:
        print(f"[FAIL] {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
