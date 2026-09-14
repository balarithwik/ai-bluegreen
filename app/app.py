import os
import random
import time

from flask import Flask, jsonify, Response
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST

app = Flask(__name__)

APP_VERSION = os.getenv("APP_VERSION", "v1")
DELAY_MS = int(os.getenv("DELAY_MS", "50"))
ERROR_RATE = float(os.getenv("ERROR_RATE", "0.01"))

REQUESTS = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["path", "status", "version"],
)

LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds",
    ["path", "version"],
)

APP_VERSION_INFO = Gauge(
    "app_version_info",
    "Application version information",
    ["version"],
)

APP_VERSION_INFO.labels(version=APP_VERSION).set(1)


@app.get("/")
def home():
    return jsonify(
        application="AI Blue-Green Demo",
        version=APP_VERSION,
        delay_ms=DELAY_MS,
        error_rate=ERROR_RATE,
    )


@app.get("/health")
def health():
    start = time.perf_counter()

    try:
        response = jsonify(
            status="UP",
            version=APP_VERSION,
        )
        REQUESTS.labels(
            path="/health",
            status="200",
            version=APP_VERSION,
        ).inc()
        return response, 200
    finally:
        LATENCY.labels(
            path="/health",
            version=APP_VERSION,
        ).observe(time.perf_counter() - start)


@app.get("/api/orders")
def orders():
    start = time.perf_counter()

    try:
        time.sleep(DELAY_MS / 1000.0)

        if random.random() < ERROR_RATE:
            REQUESTS.labels(
                path="/api/orders",
                status="500",
                version=APP_VERSION,
            ).inc()

            return jsonify(
                status="FAILED",
                version=APP_VERSION,
                message="Simulated order processing failure",
            ), 500

        REQUESTS.labels(
            path="/api/orders",
            status="200",
            version=APP_VERSION,
        ).inc()

        return jsonify(
            status="SUCCESS",
            version=APP_VERSION,
            message="Order processed successfully",
        ), 200
    finally:
        LATENCY.labels(
            path="/api/orders",
            version=APP_VERSION,
        ).observe(time.perf_counter() - start)


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, threaded=True)
