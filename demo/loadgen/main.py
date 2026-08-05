from __future__ import annotations

import asyncio
import contextlib
import os
import random
import signal

import httpx
import structlog
from obstack import setup_worker_observability
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from prometheus_client import Counter

log = structlog.get_logger("loadgen")

TARGET = os.environ.get("LOADGEN_TARGET", "http://demo-api:8000")
RATE_PER_S = float(os.environ.get("LOADGEN_RATE", "5"))
METRICS_PORT = int(os.environ.get("LOADGEN_METRICS_PORT", "9101"))

# Weights, not probabilities: the resulting error rate (~2%) and p99 (~/slow's
# upper bound) are constants every dashboard from M7 onward can be read against.
_MIX: tuple[tuple[str, int], ...] = (
    ("/ok", 70),
    ("/items", 15),
    ("/db", 8),
    ("/slow", 5),
    ("/boom", 2),
)
_ROUTES = [route for route, weight in _MIX for _ in range(weight)]


def _next_path() -> tuple[str, str]:
    route = random.choice(_ROUTES)
    if route == "/items":
        return f"/items/{random.randint(1, 50)}", "/items/{item_id}"
    return route, route


async def _run(
    client: httpx.AsyncClient,
    requests: Counter,
    identity: dict[str, str],
    stopping: asyncio.Event,
) -> None:
    interval = 1.0 / RATE_PER_S
    while not stopping.is_set():
        path, route = _next_path()
        try:
            response = await client.get(path)
        except httpx.HTTPError as exc:
            requests.labels(**identity, route=route, status_code="error").inc()
            log.warning("request failed", route=route, error=str(exc))
        else:
            requests.labels(
                **identity, route=route, status_code=str(response.status_code)
            ).inc()
            emit = log.warning if response.status_code >= 500 else log.debug
            emit("request", route=route, status_code=response.status_code)

        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(stopping.wait(), timeout=interval)


async def main() -> None:
    obs = setup_worker_observability(metrics_port=METRICS_PORT)

    # Propagates traceparent, so a trace covers both services and Tempo's
    # service graph has an edge to draw.
    HTTPXClientInstrumentor().instrument(tracer_provider=obs.tracer_provider)

    # Generic name, identity in labels: docs/labels.md §4.4 bars `app` from a
    # metric name and says the same of `service` — so not loadgen_requests_total.
    requests = Counter(
        "client_requests_total",
        "Outbound HTTP requests issued by this process",
        ["app", "service", "env", "route", "status_code"],
        registry=obs.registry,
    )
    identity = {
        "app": obs.settings.app,
        "service": obs.settings.service,
        "env": obs.settings.env,
    }

    stopping = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stopping.set)

    log.info("loadgen started", target=TARGET, rate_per_s=RATE_PER_S)
    async with httpx.AsyncClient(base_url=TARGET, timeout=10.0) as client:
        await _run(client, requests, identity, stopping)

    log.info("loadgen stopping")
    obs.shutdown()


if __name__ == "__main__":
    asyncio.run(main())
