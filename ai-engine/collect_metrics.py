import argparse
import json
import math
import re
import urllib.parse
import urllib.request
from datetime import datetime, timezone


def prometheus_query(base_url: str, query: str):
    params = urllib.parse.urlencode({"query": query})
    url = f"{base_url.rstrip('/')}/api/v1/query?{params}"

    with urllib.request.urlopen(url, timeout=15) as response:
        payload = json.loads(response.read().decode("utf-8"))

    if payload.get("status") != "success":
        raise RuntimeError(f"Prometheus query failed: {query}")

    result = payload.get("data", {}).get("result", [])
    if not result:
        return 0.0

    value = result[0].get("value", [None, "0"])[1]

    try:
        number = float(value)
        if math.isnan(number) or math.isinf(number):
            return 0.0
        return number
    except (TypeError, ValueError):
        return 0.0


def collect_environment(base_url: str, namespace: str, pod_hash: str, expected_replicas: int):
    pod_regex = f"ai-bluegreen-rollout-{re.escape(pod_hash)}-.*"

    cpu_cores = prometheus_query(
        base_url,
        f'sum(rate(container_cpu_usage_seconds_total{{namespace="{namespace}",pod=~"{pod_regex}",container!="",image!=""}}[2m]))'
    )

    cpu_limit_cores = prometheus_query(
        base_url,
        f'sum(kube_pod_container_resource_limits{{namespace="{namespace}",pod=~"{pod_regex}",resource="cpu",unit="core"}})'
    )

    memory_bytes = prometheus_query(
        base_url,
        f'sum(container_memory_working_set_bytes{{namespace="{namespace}",pod=~"{pod_regex}",container!="",image!=""}})'
    )

    memory_limit_bytes = prometheus_query(
        base_url,
        f'sum(kube_pod_container_resource_limits{{namespace="{namespace}",pod=~"{pod_regex}",resource="memory",unit="byte"}})'
    )

    restarts = prometheus_query(
        base_url,
        f'sum(kube_pod_container_status_restarts_total{{namespace="{namespace}",pod=~"{pod_regex}"}})'
    )

    ready_pods = prometheus_query(
        base_url,
        f'sum(kube_pod_status_ready{{namespace="{namespace}",pod=~"{pod_regex}",condition="true"}} == 1)'
    )

    pod_count = prometheus_query(
        base_url,
        f'count(kube_pod_info{{namespace="{namespace}",pod=~"{pod_regex}"}})'
    )

    cpu_pct = 0.0
    if cpu_limit_cores > 0:
        cpu_pct = (cpu_cores / cpu_limit_cores) * 100.0

    memory_pct = 0.0
    if memory_limit_bytes > 0:
        memory_pct = (memory_bytes / memory_limit_bytes) * 100.0

    return {
        "podTemplateHash": pod_hash,
        "expectedReplicas": expected_replicas,
        "podCount": int(round(pod_count)),
        "readyPods": int(round(ready_pods)),
        "containerRestarts": int(round(restarts)),
        "cpuCores": round(cpu_cores, 5),
        "cpuMillicores": round(cpu_cores * 1000.0, 2),
        "cpuLimitCores": round(cpu_limit_cores, 5),
        "cpuUtilizationPctOfLimit": round(cpu_pct, 2),
        "memoryBytes": int(round(memory_bytes)),
        "memoryMiB": round(memory_bytes / (1024 * 1024), 2),
        "memoryLimitBytes": int(round(memory_limit_bytes)),
        "memoryLimitMiB": round(memory_limit_bytes / (1024 * 1024), 2),
        "memoryUtilizationPctOfLimit": round(memory_pct, 2),
    }


def main():
    parser = argparse.ArgumentParser(description="Collect Blue/Green Prometheus telemetry.")
    parser.add_argument("--prometheus-url", required=True)
    parser.add_argument("--namespace", default="ai-bluegreen")
    parser.add_argument("--blue-hash", required=True)
    parser.add_argument("--green-hash", required=True)
    parser.add_argument("--expected-replicas", type=int, default=2)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    blue = collect_environment(
        args.prometheus_url,
        args.namespace,
        args.blue_hash,
        args.expected_replicas,
    )

    green = collect_environment(
        args.prometheus_url,
        args.namespace,
        args.green_hash,
        args.expected_replicas,
    )

    telemetry = {
        "namespace": args.namespace,
        "prometheusUrl": args.prometheus_url,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "blue": blue,
        "green": green,
    }

    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(telemetry, handle, indent=2)

    print("==========================================")
    print(" PROMETHEUS BLUE-GREEN TELEMETRY")
    print("==========================================")
    for label, data in (("BLUE", blue), ("GREEN", green)):
        print(f"\n{label}")
        print("------------------------------------------")
        print(f"Pod hash         : {data['podTemplateHash']}")
        print(f"Pods Ready       : {data['readyPods']}/{data['expectedReplicas']}")
        print(f"Restarts         : {data['containerRestarts']}")
        print(f"CPU              : {data['cpuMillicores']} m")
        print(f"CPU % of limit   : {data['cpuUtilizationPctOfLimit']} %")
        print(f"Memory           : {data['memoryMiB']} MiB")
        print(f"Memory % of limit: {data['memoryUtilizationPctOfLimit']} %")


if __name__ == "__main__":
    main()
