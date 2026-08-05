from __future__ import annotations

import logging
import sys
from typing import Any

import structlog
from opentelemetry import trace
from structlog.contextvars import bind_contextvars, clear_contextvars
from structlog.types import EventDict, Processor, WrappedLogger

from obstack.settings import ObservabilitySettings

# httpx logs one INFO line per outbound request, duplicating whatever the caller
# already logs — the same relationship uvicorn.access has to our own HTTP line.
_QUIET_LOGGERS = ("sqlalchemy.engine", "uvicorn.access", "httpx", "watchfiles")

# uvicorn and gunicorn install their own handlers with propagate=False, so
# configuring the root logger alone never reaches them: startup lines and the
# "Exception in ASGI application" traceback stay plain text, and one traceback
# becomes one Loki line per frame.
_ADOPTED_LOGGERS = (
    "uvicorn",
    "uvicorn.error",
    "uvicorn.access",
    "gunicorn",
    "gunicorn.error",
    "gunicorn.access",
)


def bind_request_context(**fields: Any) -> None:
    bind_contextvars(**fields)


def _add_otel_context(
    _logger: WrappedLogger, _method: str, event_dict: EventDict
) -> EventDict:
    ctx = trace.get_current_span().get_span_context()
    if ctx is not None and ctx.trace_id != 0:
        event_dict["trace_id"] = format(ctx.trace_id, "032x")
        event_dict["span_id"] = format(ctx.span_id, "016x")
    return event_dict


def _renderer(settings: ObservabilitySettings) -> Processor:
    fmt = settings.log_format
    if fmt == "auto":
        fmt = "console" if settings.env == "local" else "json"
    if fmt == "console":
        return structlog.dev.ConsoleRenderer()
    return structlog.processors.JSONRenderer()


def configure_logging(settings: ObservabilitySettings) -> None:
    shared_processors: list[Processor] = [
        structlog.contextvars.merge_contextvars,
        _add_otel_context,
        structlog.stdlib.filter_by_level,
        structlog.stdlib.add_logger_name,
        structlog.stdlib.add_log_level,
        structlog.stdlib.PositionalArgumentsFormatter(),
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.ExceptionRenderer(),
        structlog.processors.UnicodeDecoder(),
    ]

    structlog.configure(
        processors=[
            *shared_processors,
            structlog.stdlib.ProcessorFormatter.wrap_for_formatter,
        ],
        wrapper_class=structlog.stdlib.BoundLogger,
        logger_factory=structlog.stdlib.LoggerFactory(),
        cache_logger_on_first_use=True,
    )

    # ProcessorFormatter passes logger=None for stdlib records, and filter_by_level
    # reads logger.disabled. Level filtering for those records is root_logger's job.
    foreign_pre_chain = [
        p for p in shared_processors if p is not structlog.stdlib.filter_by_level
    ]

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(
        structlog.stdlib.ProcessorFormatter(
            processors=[
                structlog.stdlib.ProcessorFormatter.remove_processors_meta,
                _renderer(settings),
            ],
            foreign_pre_chain=foreign_pre_chain,
        )
    )

    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(settings.log_level.upper())

    for name in _ADOPTED_LOGGERS:
        adopted = logging.getLogger(name)
        adopted.handlers.clear()
        adopted.propagate = True

    for name in _QUIET_LOGGERS:
        logging.getLogger(name).setLevel(logging.WARNING)

    clear_contextvars()
