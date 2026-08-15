# Copyright (c) 2026 Atick Faisal
# SPDX-License-Identifier: MIT

from __future__ import annotations

import time
from collections.abc import Collection

import structlog
from opentelemetry import trace
from starlette.routing import Match
from starlette.types import ASGIApp, Message, Receive, Scope, Send
from structlog.contextvars import clear_contextvars

from obstack.metrics import Metrics
from obstack.settings import ObservabilitySettings

log = structlog.get_logger("obstack.http")


def _route_pattern(scope: Scope) -> str:
    path = getattr(scope.get("route"), "path", None)
    if isinstance(path, str):
        return path
    app = scope.get("app")
    if app is not None:
        for route in app.routes:
            match, _ = route.matches(scope)
            if match == Match.FULL:
                return str(getattr(route, "path", ""))
    return ""


def _exemplar() -> dict[str, str] | None:
    ctx = trace.get_current_span().get_span_context()
    if ctx.trace_id != 0:
        return {"trace_id": format(ctx.trace_id, "032x")}
    return None


def _client_ip(scope: Scope) -> str | None:
    client = scope.get("client")
    return client[0] if client else None


class PrometheusMiddleware:
    def __init__(
        self,
        app: ASGIApp,
        *,
        metrics: Metrics,
        settings: ObservabilitySettings,
        excluded_paths: Collection[str] = (),
    ) -> None:
        self.app = app
        self.metrics = metrics
        self.identity = {
            "app": settings.app,
            "service": settings.service,
            "env": settings.env,
        }
        self.excluded_paths = frozenset(excluded_paths)

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope["path"] in self.excluded_paths:
            await self.app(scope, receive, send)
            return

        method = scope["method"]
        # Default to 500: an unhandled exception never reaches http.response.start,
        # and the request must still be counted as the failure it was.
        status_code = "500"

        async def capture_status(message: Message) -> None:
            nonlocal status_code
            if message["type"] == "http.response.start":
                status_code = str(message["status"])
            await send(message)

        self.metrics.in_progress.labels(**self.identity, method=method).inc()
        started = time.perf_counter()
        try:
            await self.app(scope, receive, capture_status)
        except Exception as exc:
            self.metrics.exceptions.labels(
                **self.identity,
                method=method,
                route=_route_pattern(scope),
                exception_type=type(exc).__name__,
            ).inc()
            raise
        finally:
            duration = time.perf_counter() - started
            route = _route_pattern(scope)
            exemplar = _exemplar()
            self.metrics.in_progress.labels(**self.identity, method=method).dec()
            self.metrics.requests.labels(
                **self.identity, method=method, route=route, status_code=status_code
            ).inc(exemplar=exemplar)
            self.metrics.duration.labels(**self.identity, method=method, route=route).observe(
                duration, exemplar=exemplar
            )


class RequestLoggingMiddleware:
    def __init__(self, app: ASGIApp, *, excluded_paths: Collection[str] = ()) -> None:
        self.app = app
        self.excluded_paths = frozenset(excluded_paths)

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope["path"] in self.excluded_paths:
            await self.app(scope, receive, send)
            return

        clear_contextvars()
        status_code = 500

        async def capture_status(message: Message) -> None:
            nonlocal status_code
            if message["type"] == "http.response.start":
                status_code = int(message["status"])
            await send(message)

        started = time.perf_counter()
        try:
            await self.app(scope, receive, capture_status)
        except Exception:
            log.exception(
                "HTTP",
                method=scope["method"],
                path=scope["path"],
                route=_route_pattern(scope),
                status_code=status_code,
                duration_ms=round((time.perf_counter() - started) * 1000, 1),
                client_ip=_client_ip(scope),
            )
            raise

        emit = log.error if status_code >= 500 else log.warning if status_code >= 400 else log.info
        emit(
            "HTTP",
            method=scope["method"],
            path=scope["path"],
            route=_route_pattern(scope),
            status_code=status_code,
            duration_ms=round((time.perf_counter() - started) * 1000, 1),
            client_ip=_client_ip(scope),
        )
