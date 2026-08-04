from __future__ import annotations

from collections.abc import Collection
from dataclasses import dataclass
from typing import TYPE_CHECKING

from fastapi import FastAPI
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from prometheus_client import CollectorRegistry, start_http_server
from starlette.responses import Response

from obskit.errors import setup_error_reporting
from obskit.logging import configure_logging
from obskit.metrics import build_metrics, render
from obskit.middleware import PrometheusMiddleware, RequestLoggingMiddleware
from obskit.settings import ObservabilitySettings
from obskit.tracing import build_tracer_provider, instrument

if TYPE_CHECKING:
    from sqlalchemy import Engine
    from sqlalchemy.ext.asyncio import AsyncEngine


@dataclass(frozen=True, slots=True)
class Observability:
    settings: ObservabilitySettings
    registry: CollectorRegistry
    tracer_provider: TracerProvider | None

    def shutdown(self, timeout_s: float = 5.0) -> None:
        if self.tracer_provider is None:
            return
        self.tracer_provider.force_flush(int(timeout_s * 1000))
        self.tracer_provider.shutdown()


def _bootstrap(settings: ObservabilitySettings | None) -> tuple[
    ObservabilitySettings, TracerProvider | None
]:
    resolved = settings if settings is not None else ObservabilitySettings.load()
    configure_logging(resolved)
    setup_error_reporting(resolved)
    provider = build_tracer_provider(resolved)
    if provider is not None:
        trace.set_tracer_provider(provider)
    return resolved, provider


def setup_observability(
    app: FastAPI,
    *,
    settings: ObservabilitySettings | None = None,
    engine: Engine | AsyncEngine | None = None,
    excluded_paths: Collection[str] = (),
) -> Observability:
    resolved, provider = _bootstrap(settings)
    metrics = build_metrics(resolved)
    excluded = frozenset({resolved.metrics_path, *excluded_paths})

    if resolved.metrics_enabled:
        app.add_middleware(
            PrometheusMiddleware,
            metrics=metrics,
            settings=resolved,
            excluded_paths=excluded,
        )

    app.add_middleware(RequestLoggingMiddleware, excluded_paths=excluded)

    if resolved.metrics_enabled:

        @app.get(resolved.metrics_path, include_in_schema=False)
        def expose_metrics() -> Response:
            body, content_type = render(metrics.registry)
            return Response(content=body, media_type=content_type)

    # Last, so the OTel middleware wraps ours: both the exemplar and the log line's
    # trace_id need the server span to already be current.
    if provider is not None:
        instrument(app, provider, engine, excluded_paths=excluded)

    return Observability(settings=resolved, registry=metrics.registry, tracer_provider=provider)


def setup_worker_observability(
    *,
    settings: ObservabilitySettings | None = None,
    metrics_port: int | None = None,
) -> Observability:
    resolved, provider = _bootstrap(settings)
    metrics = build_metrics(resolved)

    if metrics_port is not None and resolved.metrics_enabled:
        start_http_server(metrics_port, registry=metrics.registry)

    return Observability(settings=resolved, registry=metrics.registry, tracer_provider=provider)
