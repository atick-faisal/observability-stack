from __future__ import annotations

from dataclasses import dataclass
from typing import cast

from prometheus_client import (
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    Info,
    disable_created_metrics,
)
from prometheus_client.openmetrics.exposition import (
    CONTENT_TYPE_LATEST,
    generate_latest,  # pyright: ignore[reportUnknownVariableType]  — untyped upstream
)

from obstack.settings import ObservabilitySettings

disable_created_metrics()

_IDENTITY = ("app", "service", "env")
_BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0)


@dataclass(frozen=True, slots=True)
class Metrics:
    registry: CollectorRegistry
    requests: Counter
    duration: Histogram
    exceptions: Counter
    in_progress: Gauge


def build_metrics(settings: ObservabilitySettings) -> Metrics:
    registry = CollectorRegistry()

    metrics = Metrics(
        registry=registry,
        requests=Counter(
            "fastapi_requests_total",
            "Total request count",
            [*_IDENTITY, "method", "route", "status_code"],
            registry=registry,
        ),
        duration=Histogram(
            "fastapi_requests_duration_seconds",
            "Request duration in seconds",
            [*_IDENTITY, "method", "route"],
            buckets=_BUCKETS,
            registry=registry,
        ),
        exceptions=Counter(
            "fastapi_exceptions_total",
            "Total number of unhandled exceptions",
            [*_IDENTITY, "method", "route", "exception_type"],
            registry=registry,
        ),
        in_progress=Gauge(
            "fastapi_requests_in_progress",
            "Requests currently being processed",
            [*_IDENTITY, "method"],
            registry=registry,
        ),
    )

    Info("fastapi_app", "FastAPI application information", registry=registry).info(
        {
            "app": settings.app,
            "service": settings.service,
            "env": settings.env,
            "version": settings.version,
        }
    )

    return metrics


def render(registry: CollectorRegistry) -> tuple[bytes, str]:
    return cast(bytes, generate_latest(registry)), CONTENT_TYPE_LATEST
