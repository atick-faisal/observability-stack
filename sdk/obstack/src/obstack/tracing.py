# Copyright (c) 2026 Atick Faisal
# SPDX-License-Identifier: MIT

from __future__ import annotations

import os
from collections.abc import Collection
from typing import TYPE_CHECKING, Any

import structlog
from fastapi import FastAPI
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, SpanExporter
from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased

from obstack.settings import ObservabilitySettings

if TYPE_CHECKING:
    from sqlalchemy import Engine
    from sqlalchemy.ext.asyncio import AsyncEngine

log = structlog.get_logger("obstack.tracing")

_HTTP_TRACES_PATH = "/v1/traces"
_SEMCONV_OPT_IN = "OTEL_SEMCONV_STABILITY_OPT_IN"


def apply_semconv_opt_in() -> None:
    # The HTTP instrumentations read this once, on first use, and cache the answer
    # process-wide. Left unset they emit the pre-1.0 attribute names
    # (http.status_code, http.method, http.target), and anything configured against
    # the stable ones — Tempo's http.response.status_code span-metrics dimension,
    # for instance — silently produces nothing. setdefault, so an app that has
    # chosen "http/dup" during its own migration keeps it.
    os.environ.setdefault(_SEMCONV_OPT_IN, "http")


def build_resource(settings: ObservabilitySettings) -> Resource:
    return Resource.create(
        {
            "app": settings.app,
            "service": settings.service,
            "env": settings.env,
            "host": settings.host,
            "service.name": settings.service_name,
            "service.version": settings.version,
            "deployment.environment.name": settings.env,
        }
    )


def _build_exporter(settings: ObservabilitySettings) -> SpanExporter:
    endpoint = str(settings.otlp_endpoint)
    if settings.otlp_protocol == "grpc":
        from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

        return OTLPSpanExporter(endpoint=endpoint, insecure=not endpoint.startswith("https"))

    from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
        OTLPSpanExporter as HTTPSpanExporter,
    )

    if not endpoint.endswith(_HTTP_TRACES_PATH):
        endpoint = f"{endpoint.rstrip('/')}{_HTTP_TRACES_PATH}"
    return HTTPSpanExporter(endpoint=endpoint)


def build_tracer_provider(settings: ObservabilitySettings) -> TracerProvider | None:
    # Before any instrumentor is constructed, and on the one path both
    # setup_observability and setup_worker_observability take.
    apply_semconv_opt_in()

    if not settings.otlp_endpoint:
        return None

    try:
        exporter = _build_exporter(settings)
    except ImportError:
        log.error(
            "otlp exporter unavailable, tracing disabled",
            protocol=settings.otlp_protocol,
            hint=f'install obstack["{settings.otlp_protocol}"]',
        )
        return None
    except Exception as exc:
        log.error(
            "otlp exporter construction failed, tracing disabled",
            protocol=settings.otlp_protocol,
            endpoint=settings.otlp_endpoint,
            error=str(exc),
        )
        return None

    provider = TracerProvider(
        resource=build_resource(settings),
        sampler=ParentBased(TraceIdRatioBased(settings.trace_sample_ratio)),
    )
    provider.add_span_processor(BatchSpanProcessor(exporter))
    return provider


def instrument(
    app: FastAPI,
    provider: TracerProvider,
    engine: Engine | AsyncEngine | None = None,
    excluded_paths: Collection[str] = (),
) -> None:
    # excluded_urls: without it the scrape endpoint is traced too, so every 15s
    # scrape mints a trace that describes nothing but the act of observing.
    # exclude_spans: the ASGI "http send"/"http receive" children triple the span
    # count per request and carry nothing the server span does not already have.
    FastAPIInstrumentor.instrument_app(
        app,
        tracer_provider=provider,
        excluded_urls=",".join(excluded_paths) or None,
        exclude_spans=["send", "receive"],
    )
    if engine is None:
        return

    try:
        from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
    except ImportError:
        log.error('sqlalchemy instrumentation unavailable, install obstack["sqlalchemy"]')
        return

    target: Any = getattr(engine, "sync_engine", engine)
    SQLAlchemyInstrumentor().instrument(engine=target, tracer_provider=provider)
