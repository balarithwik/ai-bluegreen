#!/usr/bin/env python3
import html
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
RESULTS = PROJECT_ROOT / "results"
RUNTIME = PROJECT_ROOT / "runtime"
REPORT_DIR = RUNTIME / "reports"
REPORT_FILE = REPORT_DIR / "ai-bluegreen-deployment-report.html"
EMAIL_FILE = REPORT_DIR / "ai-bluegreen-email-summary.html"
META_FILE = REPORT_DIR / "email-metadata.json"


def load_json(path):
    path = Path(path)
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception:
        return {}


def esc(value):
    if value is None:
        return "N/A"
    return html.escape(str(value))


def num(value, default=0.0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def integer(value, default=0):
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return default


def fmt(value, decimals=2, suffix=""):
    if value is None or value == "":
        return "N/A"
    try:
        return f"{float(value):.{decimals}f}{suffix}"
    except (TypeError, ValueError):
        return f"{esc(value)}{suffix}"


def badge(text, kind="neutral"):
    return f'<span class="badge {kind}">{esc(text)}</span>'


def status_kind(value):
    value = str(value or "").upper()
    if value in {"PASS", "PROMOTE", "KEEP_GREEN", "HEALTHY", "SUCCESS", "SAFE", "GREEN"}:
        return "good"
    if value in {"PAUSE", "WARNING", "WARN", "MEDIUM", "REVIEW"}:
        return "warn"
    if value in {"FAIL", "FAILED", "ABORT", "ROLLBACK_REQUIRED", "CRITICAL", "HIGH"}:
        return "bad"
    if value in {"BLUE", "ROLLED_BACK_TO_BLUE"}:
        return "blue"
    return "neutral"


def metric_card(label, value, note="", kind="neutral"):
    return f'''<div class="metric-card {kind}">
      <div class="metric-label">{esc(label)}</div>
      <div class="metric-value">{esc(value)}</div>
      <div class="metric-note">{esc(note)}</div>
    </div>'''


def ai_card(title, decision):
    if not decision:
        return f'''<div class="panel"><h3>{esc(title)}</h3><p class="muted">No AI decision evidence was generated for this stage.</p></div>'''

    final_decision = str(decision.get("finalDecision", "N/A"))
    ai_hint = str(decision.get("aiDecisionHint", "N/A"))
    risk = decision.get("finalRiskScore", "N/A")
    base = decision.get("baseRiskScore", "N/A")
    adjustment = decision.get("aiRiskAdjustment", "N/A")
    confidence = decision.get("aiConfidence", "N/A")
    model = decision.get("model", "N/A")
    summary = decision.get("aiSummary", "")
    policy_reason = decision.get("policyReason", "")
    factors = decision.get("aiRiskFactors", []) or []
    hard_failures = decision.get("hardFailures", []) or []
    factor_html = "".join(f"<li>{esc(x)}</li>" for x in factors) or "<li>None reported.</li>"
    hard_html = "".join(f"<li>{esc(x)}</li>" for x in hard_failures) or "<li>None.</li>"
    adjustment_display = f"{adjustment:+}" if isinstance(adjustment, (int, float)) else str(adjustment)

    return f'''<div class="panel">
      <div class="panel-title-row"><h3>{esc(title)}</h3>{badge(final_decision, status_kind(final_decision))}</div>
      <div class="grid grid-4 compact-grid">
        {metric_card("Final Risk", f"{risk}/100", "Policy-controlled risk score")}
        {metric_card("Base Risk", f"{base}/100", "Deterministic supporting risk")}
        {metric_card("AI Adjustment", adjustment_display, "Bounded contextual adjustment")}
        {metric_card("Confidence", f"{confidence}%", f"Model: {model}")}
      </div>
      <div class="ai-summary"><strong>AI contextual summary:</strong> {esc(summary or "N/A")}</div>
      <div class="ai-summary"><strong>AI decision hint:</strong> {esc(ai_hint)} <span class="muted">(advisory; hard safety policy retains control)</span></div>
      <div class="ai-summary"><strong>Policy reason:</strong> {esc(policy_reason or "N/A")}</div>
      <div class="grid grid-2">
        <div><div class="subhead">AI risk factors</div><ul>{factor_html}</ul></div>
        <div><div class="subhead">Hard safety failures</div><ul>{hard_html}</ul></div>
      </div>
    </div>'''


def jmeter_row(name, summary, default_users):
    users = integer(summary.get("concurrentUsers"), default_users)
    return f'''<tr>
      <td><strong>{esc(name)}</strong></td><td>{users}</td>
      <td>{integer(summary.get("totalRequests"))}</td><td>{integer(summary.get("successfulRequests"))}</td>
      <td>{integer(summary.get("failedRequests"))}</td><td>{fmt(summary.get("errorRatePct"), 3, "%")}</td>
      <td>{fmt(summary.get("averageResponseMs"), 2, " ms")}</td><td>{fmt(summary.get("p95ResponseMs"), 2, " ms")}</td>
      <td>{fmt(summary.get("throughputRps"), 2, " req/s")}</td>
    </tr>'''


def bar(label, value, maximum, display, kind="accent"):
    v = max(0.0, num(value))
    maxv = max(float(maximum), 1.0)
    pct = min(100.0, v / maxv * 100.0)
    return f'''<div class="bar-row"><div class="bar-label">{esc(label)}</div>
      <div class="bar-track"><div class="bar-fill {kind}" style="width:{pct:.1f}%"></div></div>
      <div class="bar-value">{esc(display)}</div></div>'''


def telemetry_table(telemetry):
    rows = []
    for env in ("blue", "green"):
        item = telemetry.get(env, {}) if isinstance(telemetry, dict) else {}
        if not item:
            continue
        rows.append(f'''<tr>
          <td>{esc(env.upper())}</td>
          <td>{esc(item.get("readyPods", "N/A"))}/{esc(item.get("expectedReplicas", item.get("expectedPods", "N/A")))}</td>
          <td>{esc(item.get("containerRestarts", item.get("restarts", "N/A")))}</td>
          <td>{fmt(item.get("cpuMillicores"), 2, " m")}</td>
          <td>{fmt(item.get("cpuUtilizationPctOfLimit", item.get("cpuPercentOfLimit")), 2, "%")}</td>
          <td>{fmt(item.get("memoryMiB"), 2, " MiB")}</td>
          <td>{fmt(item.get("memoryUtilizationPctOfLimit", item.get("memoryPercentOfLimit")), 2, "%")}</td>
        </tr>''')
    return "".join(rows) or '<tr><td colspan="7">No telemetry evidence available.</td></tr>'


def timeline_rows(timeline):
    if not timeline:
        return '<tr><td colspan="4">Pipeline timeline will be populated by Jenkins.</td></tr>'
    stages = timeline.get("stages", timeline if isinstance(timeline, list) else [])
    if isinstance(stages, dict):
        stages = list(stages.values())
    rows = []
    if isinstance(stages, list):
        for item in stages:
            if not isinstance(item, dict):
                continue
            rows.append(f'''<tr><td>{esc(item.get("stage", item.get("name", "N/A")))}</td>
              <td>{esc(item.get("status", "N/A"))}</td>
              <td>{esc(item.get("startedAt", item.get("start", "N/A")))}</td>
              <td>{esc(item.get("durationSeconds", item.get("duration", "N/A")))}</td></tr>''')
    return "".join(rows) or '<tr><td colspan="4">No stage timing entries were found.</td></tr>'


def main():
    REPORT_DIR.mkdir(parents=True, exist_ok=True)

    blue = load_json(RESULTS / "blue-baseline" / "summary.json")
    green = load_json(RESULTS / "green-validation" / "summary.json")
    green_comp = load_json(RESULTS / "green-validation" / "comparison.json")
    pre_ai = load_json(RESULTS / "ai-analysis" / "decision.json")
    pre_telemetry = load_json(RESULTS / "ai-analysis" / "telemetry.json")
    promotion = load_json(RESULTS / "promotion" / "promotion-state.json")
    post = load_json(RESULTS / "post-promotion" / "summary.json")
    post_comp = load_json(RESULTS / "post-promotion" / "comparison.json")
    post_ai = load_json(RESULTS / "post-promotion" / "decision.json")
    post_telemetry = load_json(RESULTS / "post-promotion" / "telemetry.json")
    final_state = load_json(RESULTS / "post-promotion" / "final-state.json")
    rollback = load_json(RESULTS / "rollback" / "rollback-state.json")
    scenario_control = load_json(RESULTS / "scenario-control" / "post-validation-condition.json")
    timeline = load_json(RUNTIME / "pipeline-timeline.json")

    scenario = os.getenv("DEMO_SCENARIO") or scenario_control.get("scenario") or "N/A"
    build_number = os.getenv("BUILD_NUMBER", "LOCAL")
    job_name = os.getenv("JOB_NAME", "AI-BlueGreen-Deployment")
    build_url = os.getenv("BUILD_URL", "")

    rollback_done = bool(rollback.get("rollbackCompleted") is True or rollback.get("finalAction") == "ROLLED_BACK_TO_BLUE")
    action = str(final_state.get("finalAction", "NOT_RUN")).upper()
    if rollback_done:
        action = "ROLLED_BACK_TO_BLUE"

    if action == "KEEP_GREEN":
        prod_env, prod_version = "GREEN", final_state.get("productionVersion", "v2-healthy")
        headline = "Green promoted and retained"
        conclusion = ("The deployment completed successfully. Green satisfied preview validation, was approved for promotion, "
                      "and remained within the post-promotion production acceptance and runtime safety envelope.")
    elif action == "ROLLED_BACK_TO_BLUE":
        prod_env = "BLUE"
        prod_version = rollback.get("restoredVersion") or rollback.get("productionVersion") or "v1-healthy"
        headline = "Risk detected; Blue successfully restored"
        conclusion = ("The resilience control operated as designed. Green was promoted only after passing preview validation, "
                      "a later production degradation was detected from live evidence, and traffic was safely restored to the known-good Blue version.")
    elif action == "ROLLBACK_REQUIRED":
        prod_env, prod_version = "GREEN", "v2-healthy"
        headline = "Rollback required"
        conclusion = "Post-promotion validation identified unacceptable risk. The deployment must not remain on Green until recovery action is completed."
    else:
        prod_env = "BLUE" if str(pre_ai.get("finalDecision", "")).upper() != "PROMOTE" else "UNKNOWN"
        prod_version = "v1-healthy" if prod_env == "BLUE" else "N/A"
        headline = "Deployment ended without a final retained state"
        conclusion = "The automated workflow did not produce a final retained Green or verified Blue rollback state. Review the execution evidence before further action."

    pre_decision = str(pre_ai.get("finalDecision", "N/A"))
    post_decision = str(post_ai.get("finalDecision", "N/A"))
    generated = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")

    condition_mode = scenario_control.get("conditionMode", "NONE")
    condition_activated = bool(scenario_control.get("conditionActivated", False))
    target_cpu = scenario_control.get("targetCpuPercentOfLimit", "N/A")
    condition_desc = f"{condition_mode} ({target_cpu}% target)" if condition_activated else "NONE"

    blue_users = integer(blue.get("concurrentUsers"), 10)
    green_users = integer(green.get("concurrentUsers"), 10)
    post_users = integer(post.get("concurrentUsers"), 20)

    jmeter_rows = jmeter_row("Blue Baseline", blue, blue_users) + jmeter_row("Green Preview", green, green_users) + jmeter_row("Post-Promotion", post, post_users)
    max_p95 = max(num(blue.get("p95ResponseMs")), num(green.get("p95ResponseMs")), num(post.get("p95ResponseMs")), 1.0)
    max_error = max(num(blue.get("errorRatePct")), num(green.get("errorRatePct")), num(post.get("errorRatePct")), 1.0)
    perf_bars = (
        bar("Blue P95", blue.get("p95ResponseMs"), max_p95, fmt(blue.get("p95ResponseMs"), 2, " ms"), "blue")
        + bar("Green P95", green.get("p95ResponseMs"), max_p95, fmt(green.get("p95ResponseMs"), 2, " ms"), "green")
        + bar("Post P95", post.get("p95ResponseMs"), max_p95, fmt(post.get("p95ResponseMs"), 2, " ms"), "purple")
        + bar("Blue Error", blue.get("errorRatePct"), max_error, fmt(blue.get("errorRatePct"), 3, "%"), "blue")
        + bar("Green Error", green.get("errorRatePct"), max_error, fmt(green.get("errorRatePct"), 3, "%"), "green")
        + bar("Post Error", post.get("errorRatePct"), max_error, fmt(post.get("errorRatePct"), 3, "%"), "purple")
    )

    css = '''
:root{--bg:#07101d;--panel:#101c2d;--border:#263a53;--text:#e8eef7;--muted:#96a8be;--good:#4cd97b;--warn:#ffbf47;--bad:#ff6b6b;--purple:#b18cff;--blue:#4d9cff;--green:#43d17a}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at top right,#163a5e 0,transparent 28%),radial-gradient(circle at top left,#142b4a 0,transparent 24%),var(--bg);color:var(--text);font-family:Inter,Segoe UI,Arial,sans-serif;line-height:1.5}.container{max-width:1480px;margin:0 auto;padding:34px}.hero{border:1px solid var(--border);background:linear-gradient(135deg,rgba(35,93,145,.45),rgba(16,28,45,.94));border-radius:22px;padding:34px;margin-bottom:24px;box-shadow:0 20px 60px rgba(0,0,0,.28)}.hero h1{margin:0;font-size:34px;letter-spacing:-.8px}.hero-sub{margin-top:8px;color:var(--muted);font-size:15px}.section{margin:25px 0}.section-title{font-size:21px;margin:0 0 14px}.section-sub{color:var(--muted);margin:-7px 0 16px}.grid{display:grid;gap:14px}.grid-2{grid-template-columns:repeat(2,minmax(0,1fr))}.grid-3{grid-template-columns:repeat(3,minmax(0,1fr))}.grid-4{grid-template-columns:repeat(4,minmax(0,1fr))}.metric-card,.panel{border:1px solid var(--border);background:linear-gradient(180deg,rgba(20,35,55,.94),rgba(14,27,44,.96));border-radius:16px;box-shadow:0 10px 30px rgba(0,0,0,.17)}.metric-card{padding:17px;min-height:108px}.metric-card.good{border-color:rgba(76,217,123,.42)}.metric-card.bad{border-color:rgba(255,107,107,.45)}.metric-card.blue{border-color:rgba(77,156,255,.48)}.metric-label{color:var(--muted);text-transform:uppercase;letter-spacing:.7px;font-size:11px;font-weight:700}.metric-value{font-size:23px;font-weight:750;margin-top:9px;word-break:break-word}.metric-note{color:var(--muted);font-size:12px;margin-top:5px}.panel{padding:20px}.panel h3{margin:0 0 12px;font-size:17px}.panel-title-row{display:flex;justify-content:space-between;align-items:center;gap:12px}.badge{display:inline-block;padding:4px 9px;border-radius:999px;font-size:11px;font-weight:750;letter-spacing:.4px;border:1px solid transparent}.badge.good{color:#9af0b8;background:rgba(76,217,123,.10);border-color:rgba(76,217,123,.32)}.badge.warn{color:#ffd47d;background:rgba(255,191,71,.10);border-color:rgba(255,191,71,.32)}.badge.bad{color:#ff9e9e;background:rgba(255,107,107,.10);border-color:rgba(255,107,107,.35)}.badge.blue{color:#9dc8ff;background:rgba(77,156,255,.12);border-color:rgba(77,156,255,.38)}.badge.neutral{color:#c9d6e5;background:rgba(150,168,190,.10);border-color:rgba(150,168,190,.25)}.table-wrap{overflow-x:auto;border-radius:14px;border:1px solid var(--border)}table{width:100%;border-collapse:collapse;min-width:850px;background:rgba(10,20,34,.42)}th{text-align:left;padding:12px;color:#aac0d8;background:rgba(22,42,67,.9);font-size:11px;text-transform:uppercase;letter-spacing:.55px}td{padding:12px;border-top:1px solid rgba(38,58,83,.72);font-size:13px}.muted{color:var(--muted)}.subhead{font-size:12px;color:#aac0d8;text-transform:uppercase;letter-spacing:.55px;font-weight:700;margin-top:8px}ul{margin:9px 0 0;padding-left:20px}li{margin:6px 0}.ai-summary{padding:10px 0;border-bottom:1px solid rgba(38,58,83,.55);font-size:13px}.compact-grid{margin:12px 0}.callout{padding:18px;border-radius:15px;border:1px solid var(--border);background:rgba(90,169,255,.06)}.callout.good{border-color:rgba(76,217,123,.35);background:rgba(76,217,123,.06)}.callout.blue{border-color:rgba(77,156,255,.4);background:rgba(77,156,255,.07)}.callout.bad{border-color:rgba(255,107,107,.38);background:rgba(255,107,107,.06)}.bar-row{display:grid;grid-template-columns:120px 1fr 100px;align-items:center;gap:12px;margin:12px 0}.bar-label{font-size:12px;color:#bbcadb}.bar-track{height:10px;background:#0a1422;border:1px solid #23364e;border-radius:999px;overflow:hidden}.bar-fill{height:100%;border-radius:999px}.bar-fill.blue{background:var(--blue)}.bar-fill.green{background:var(--green)}.bar-fill.purple{background:var(--purple)}.bar-value{text-align:right;font-size:12px}.footer{margin:30px 0 8px;color:var(--muted);font-size:11px;text-align:center}@media(max-width:900px){.grid-4,.grid-3,.grid-2{grid-template-columns:1fr}.container{padding:16px}.hero{padding:22px}.bar-row{grid-template-columns:90px 1fr 86px}}
'''

    body = f'''<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>AI Blue-Green Deployment Intelligence Report</title><style>{css}</style></head><body><div class="container">
<section class="hero"><h1>AI Blue-Green Deployment Intelligence Report</h1><div class="hero-sub">Jenkins build {esc(build_number)} • Scenario {esc(scenario)} • Generated {esc(generated)}</div><div style="height:18px"></div><div class="callout {status_kind(action)}"><div class="metric-label">FINAL DEPLOYMENT OUTCOME</div><div class="metric-value">{esc(headline)}</div><div class="metric-note">Production: {esc(prod_env)} / {esc(prod_version)} • Final action: {esc(action)}</div></div></section>
<section class="section"><h2 class="section-title">1. Executive Deployment Summary</h2><div class="grid grid-4">{metric_card("Final Production",prod_env,prod_version,status_kind(prod_env))}{metric_card("Pre-Promotion AI",pre_decision,f"Risk {pre_ai.get('finalRiskScore','N/A')}/100",status_kind(pre_decision))}{metric_card("Post-Validation AI",post_decision,f"Risk {post_ai.get('finalRiskScore','N/A')}/100",status_kind(post_decision))}{metric_card("Final Action",action,"Automated deployment outcome",status_kind(action))}</div><div style="height:14px"></div><div class="panel"><h3>Business conclusion</h3><p>{esc(conclusion)}</p></div></section>
<section class="section"><h2 class="section-title">2. Test Strategy & Governance</h2><p class="section-sub">Blue and Green are compared at an equal 10-user preview load. Production is then validated at 20 users. The selected demo scenario is retained as orchestration evidence only and is not passed to the AI decision engine.</p><div class="grid grid-4">{metric_card("Blue Baseline",f"{blue_users} users","Known-good production baseline","blue")}{metric_card("Green Preview",f"{green_users} users","Isolated candidate validation","good")}{metric_card("Post-Promotion",f"{post_users} users","Stronger production validation")}{metric_card("AI Scenario Knowledge","NONE","AI sees telemetry and test evidence only","good")}</div><div style="height:14px"></div><div class="panel"><div class="panel-title-row"><h3>Controlled post-validation condition</h3>{badge(condition_desc,"neutral")}</div><p class="muted">Retrospective report evidence only. The condition configuration was not included in AI input.</p></div></section>
<section class="section"><h2 class="section-title">3. JMeter Performance Validation</h2><div class="table-wrap"><table><thead><tr><th>Phase</th><th>Users</th><th>Requests</th><th>Success</th><th>Failed</th><th>Error Rate</th><th>Average</th><th>P95</th><th>Throughput</th></tr></thead><tbody>{jmeter_rows}</tbody></table></div><div style="height:14px"></div><div class="panel"><h3>Performance profile</h3>{perf_bars}</div></section>
<section class="section"><h2 class="section-title">4. Green Preview Technical Gate</h2><div class="grid grid-4">{metric_card("Technical Gate",green_comp.get('technicalGate','N/A'),"10-user Blue vs 10-user Green",status_kind(green_comp.get('technicalGate')))}{metric_card("Error Delta",fmt((green_comp.get('regressions') or {}).get('errorRateDeltaPoints'),3,' pp'),"Green minus Blue")}{metric_card("Average Regression",fmt((green_comp.get('regressions') or {}).get('averageResponseRegressionPct'),2,'%'),"Green vs Blue")}{metric_card("P95 Regression",fmt((green_comp.get('regressions') or {}).get('p95RegressionPct'),2,'%'),"Green vs Blue")}</div></section>
<section class="section"><h2 class="section-title">5. Pre-Promotion AI Intelligence</h2>{ai_card("Pre-Promotion AI Assessment",pre_ai)}<div style="height:14px"></div><div class="panel"><h3>Prometheus telemetry used by AI</h3><div class="table-wrap"><table><thead><tr><th>Environment</th><th>Ready Pods</th><th>Restarts</th><th>CPU</th><th>CPU % Limit</th><th>Memory</th><th>Memory % Limit</th></tr></thead><tbody>{telemetry_table(pre_telemetry)}</tbody></table></div></div></section>
<section class="section"><h2 class="section-title">6. Promotion Evidence</h2><div class="grid grid-4">{metric_card("Blue Hash",promotion.get('blueHash','N/A'),"Rollback reference")}{metric_card("Green Hash",promotion.get('greenHash','N/A'),"Promoted candidate")}{metric_card("Blue Revision",promotion.get('blueRevision','N/A'),"Original production revision")}{metric_card("Green Revision",promotion.get('greenRevision','N/A'),"Promoted revision")}</div></section>
<section class="section"><h2 class="section-title">7. 20-User Post-Promotion Production Validation</h2><div class="grid grid-4">{metric_card("Production Acceptance",post_comp.get('productionAcceptance',post.get('productionAcceptance','N/A')),"20-user validation evidence",status_kind(post_comp.get('productionAcceptance',post.get('productionAcceptance'))))}{metric_card("Error Rate",fmt(post.get('errorRatePct'),3,'%'),f"Limit ≤ {fmt((post_comp.get('productionThresholds') or {}).get('errorRateMaxPct'),2,'%')}")}{metric_card("Average",fmt(post.get('averageResponseMs'),2,' ms'),f"Limit ≤ {fmt((post_comp.get('productionThresholds') or {}).get('averageResponseMaxMs'),2,' ms')}")}{metric_card("P95",fmt(post.get('p95ResponseMs'),2,' ms'),f"Limit ≤ {fmt((post_comp.get('productionThresholds') or {}).get('p95ResponseMaxMs'),2,' ms')}")}</div></section>
<section class="section"><h2 class="section-title">8. Post-Validation AI Intelligence</h2>{ai_card("Post-Validation AI Assessment",post_ai)}<div style="height:14px"></div><div class="panel"><h3>Fresh post-validation telemetry</h3><div class="table-wrap"><table><thead><tr><th>Environment</th><th>Ready Pods</th><th>Restarts</th><th>CPU</th><th>CPU % Limit</th><th>Memory</th><th>Memory % Limit</th></tr></thead><tbody>{telemetry_table(post_telemetry)}</tbody></table></div></div></section>
<section class="section"><h2 class="section-title">9. Recovery / Retention Evidence</h2><div class="grid grid-4">{metric_card("Final Action",action,"Result after post-validation",status_kind(action))}{metric_card("Production Environment",prod_env,prod_version,status_kind(prod_env))}{metric_card("Rollback Completed","YES" if rollback_done else "NO","Expected NO for healthy retain-Green scenario","blue" if rollback_done else "good")}{metric_card("AI Model",post_ai.get('model',pre_ai.get('model','N/A')),"Local contextual analysis")}</div><div style="height:14px"></div><div class="callout {'blue' if rollback_done else 'good'}"><strong>{esc(headline)}</strong><br>{esc(conclusion)}</div></section>
<section class="section"><h2 class="section-title">10. Pipeline Execution Timeline</h2><div class="table-wrap"><table><thead><tr><th>Stage</th><th>Status</th><th>Started</th><th>Duration (s)</th></tr></thead><tbody>{timeline_rows(timeline)}</tbody></table></div></section>
<section class="section"><h2 class="section-title">11. Environment & Evidence</h2><div class="grid grid-3">{metric_card("Cluster","ai-bluegreen","Ephemeral Kind environment")}{metric_card("Namespace","ai-bluegreen","Application namespace")}{metric_card("Argo Strategy","Blue-Green","Active + Preview services")}{metric_card("Observability","Prometheus + Grafana","Pushgateway-backed deployment intelligence")}{metric_card("Load Test","Apache JMeter",f"10 / 10 / {post_users} users")}{metric_card("AI Runtime","Ollama",post_ai.get('model',pre_ai.get('model','qwen3:4b-instruct')))}</div></section>
<div class="footer">AI Blue-Green Deployment Intelligence • Job {esc(job_name)} • Build {esc(build_number)}{' • '+esc(build_url) if build_url else ''}</div></div></body></html>'''
    REPORT_FILE.write_text(body, encoding="utf-8")

    final_color = "#4d9cff" if action == "ROLLED_BACK_TO_BLUE" else "#43d17a" if action == "KEEP_GREEN" else "#ffbf47"
    email_body = f'''<!DOCTYPE html><html><body style="margin:0;padding:0;background:#eef2f7;font-family:Segoe UI,Arial,sans-serif;color:#1f2937"><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#eef2f7;padding:24px"><tr><td align="center"><table role="presentation" width="760" cellspacing="0" cellpadding="0" style="max-width:760px;background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 8px 28px rgba(0,0,0,.08)"><tr><td style="background:#0b1b2e;color:#fff;padding:26px 30px"><div style="font-size:12px;letter-spacing:1px;color:#9fb4cc;font-weight:700">AI BLUE-GREEN DEPLOYMENT</div><div style="font-size:25px;font-weight:750;margin-top:6px">Build #{esc(build_number)} Deployment Summary</div><div style="margin-top:6px;color:#b9c9da;font-size:13px">Scenario: {esc(scenario)}</div></td></tr><tr><td style="padding:28px 30px"><div style="border-left:5px solid {final_color};background:#f7f9fc;padding:18px 20px;border-radius:10px"><div style="font-size:12px;color:#64748b;font-weight:700;letter-spacing:.6px">FINAL OUTCOME</div><div style="font-size:22px;font-weight:750;margin-top:5px">{esc(headline)}</div><div style="font-size:14px;margin-top:8px">Production: <strong>{esc(prod_env)} / {esc(prod_version)}</strong></div></div><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="margin-top:22px"><tr><td width="50%" style="padding:10px;border:1px solid #e5e7eb"><div style="font-size:11px;color:#64748b;font-weight:700">PRE-PROMOTION AI</div><div style="font-size:18px;font-weight:700;margin-top:4px">{esc(pre_decision)}</div><div style="font-size:12px;color:#64748b">Risk {esc(pre_ai.get('finalRiskScore','N/A'))}/100 • Confidence {esc(pre_ai.get('aiConfidence','N/A'))}%</div></td><td width="50%" style="padding:10px;border:1px solid #e5e7eb"><div style="font-size:11px;color:#64748b;font-weight:700">POST-VALIDATION AI</div><div style="font-size:18px;font-weight:700;margin-top:4px">{esc(post_decision)}</div><div style="font-size:12px;color:#64748b">Risk {esc(post_ai.get('finalRiskScore','N/A'))}/100 • Confidence {esc(post_ai.get('aiConfidence','N/A'))}%</div></td></tr></table><div style="margin-top:22px;font-size:15px;font-weight:700">Performance validation</div><table role="presentation" width="100%" cellspacing="0" cellpadding="8" style="margin-top:8px;border-collapse:collapse;font-size:13px"><tr style="background:#f1f5f9"><th align="left">Phase</th><th>Users</th><th>Error</th><th>Avg</th><th>P95</th></tr><tr><td>Blue Baseline</td><td align="center">{blue_users}</td><td align="center">{fmt(blue.get('errorRatePct'),3,'%')}</td><td align="center">{fmt(blue.get('averageResponseMs'),2,' ms')}</td><td align="center">{fmt(blue.get('p95ResponseMs'),2,' ms')}</td></tr><tr><td>Green Preview</td><td align="center">{green_users}</td><td align="center">{fmt(green.get('errorRatePct'),3,'%')}</td><td align="center">{fmt(green.get('averageResponseMs'),2,' ms')}</td><td align="center">{fmt(green.get('p95ResponseMs'),2,' ms')}</td></tr><tr><td>Post-Promotion</td><td align="center">{post_users}</td><td align="center">{fmt(post.get('errorRatePct'),3,'%')}</td><td align="center">{fmt(post.get('averageResponseMs'),2,' ms')}</td><td align="center">{fmt(post.get('p95ResponseMs'),2,' ms')}</td></tr></table><div style="margin-top:22px;padding:14px 16px;background:#f8fafc;border-radius:9px;font-size:13px;line-height:1.6">{esc(conclusion)}</div><div style="margin-top:22px;font-size:13px;color:#475569"><strong>Attachments:</strong><br>1. Detailed AI Blue-Green Deployment Intelligence HTML Report<br>2. Complete JMeter evidence package for Blue, Green Preview and Post-Promotion validation</div></td></tr><tr><td style="padding:16px 30px;background:#f8fafc;color:#64748b;font-size:11px">Generated automatically by Jenkins • AI model: {esc(post_ai.get('model',pre_ai.get('model','qwen3:4b-instruct')))}</td></tr></table></td></tr></table></body></html>'''
    EMAIL_FILE.write_text(email_body, encoding="utf-8")

    subject_outcome = "KEEP GREEN" if action == "KEEP_GREEN" else "ROLLED BACK TO BLUE" if action == "ROLLED_BACK_TO_BLUE" else action.replace("_", " ")
    metadata = {"subject":f"AI Blue-Green Deployment | {subject_outcome} | {scenario} | Build #{build_number}","reportFile":REPORT_FILE.name,"emailBodyFile":EMAIL_FILE.name,"finalAction":action,"productionEnvironment":prod_env,"productionVersion":prod_version,"scenario":scenario,"buildNumber":build_number,"generatedAt":generated}
    META_FILE.write_text(json.dumps(metadata, indent=2), encoding="utf-8")

    print("==========================================")
    print(" AI BLUE-GREEN REPORT GENERATOR")
    print("==========================================")
    print(f"Scenario       : {scenario}")
    print(f"Final Action   : {action}")
    print(f"Production     : {prod_env} / {prod_version}")
    print(f"Report         : {REPORT_FILE}")
    print(f"Email Summary  : {EMAIL_FILE}")
    print(f"Email Metadata : {META_FILE}")
    print("REPORT GENERATION RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
