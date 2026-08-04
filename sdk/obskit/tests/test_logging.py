from __future__ import annotations

import json
import logging
import sys
from typing import Any

import pytest
import structlog
from opentelemetry.sdk.trace import TracerProvider

from conftest import make_settings
from obskit import bind_request_context
from obskit.logging import configure_logging


def _lines(capsys: pytest.CaptureFixture[str]) -> list[dict[str, Any]]:
    out = capsys.readouterr().out.strip()
    return [json.loads(line) for line in out.splitlines() if line]


def test_json_shape(capsys: pytest.CaptureFixture[str]) -> None:
    configure_logging(make_settings())
    structlog.get_logger("t").info("hello", answer=42)

    (line,) = _lines(capsys)
    assert line["event"] == "hello"
    assert line["level"] == "info"
    assert line["answer"] == 42
    assert line["logger"] == "t"
    assert "timestamp" in line
    assert "trace_id" not in line


def test_console_renderer_for_local(capsys: pytest.CaptureFixture[str]) -> None:
    configure_logging(make_settings(env="local"))
    structlog.get_logger("t").info("hello")

    out = capsys.readouterr().out
    assert "hello" in out
    with pytest.raises(json.JSONDecodeError):
        json.loads(out.strip())


def test_trace_id_injected_inside_a_span(capsys: pytest.CaptureFixture[str]) -> None:
    configure_logging(make_settings())
    tracer = TracerProvider().get_tracer("test")

    with tracer.start_as_current_span("unit") as span:
        structlog.get_logger("t").info("inside")
        ctx = span.get_span_context()

    (line,) = _lines(capsys)
    assert line["trace_id"] == format(ctx.trace_id, "032x")
    assert line["span_id"] == format(ctx.span_id, "016x")
    assert len(line["trace_id"]) == 32
    assert len(line["span_id"]) == 16


def test_stdlib_loggers_render_as_json(capsys: pytest.CaptureFixture[str]) -> None:
    # foreign_pre_chain must exclude filter_by_level: ProcessorFormatter passes
    # logger=None for stdlib records and filter_by_level reads logger.disabled.
    configure_logging(make_settings())
    logging.getLogger("uvicorn.error").warning("started on %s", 8000)

    (line,) = _lines(capsys)
    assert line["event"] == "started on 8000"
    assert line["level"] == "warning"


def test_uvicorn_loggers_are_adopted(capsys: pytest.CaptureFixture[str]) -> None:
    # uvicorn's dictConfig runs before the app module imports, and leaves its own
    # handler with propagate=False. Configuring root alone leaves it plain text.
    uvicorn_error = logging.getLogger("uvicorn.error")
    uvicorn_error.handlers = [logging.StreamHandler(sys.stderr)]
    uvicorn_error.propagate = False

    configure_logging(make_settings())

    assert uvicorn_error.handlers == []
    assert uvicorn_error.propagate is True

    try:
        raise ValueError("kaboom")
    except ValueError:
        uvicorn_error.exception("Exception in ASGI application")

    captured = capsys.readouterr()
    assert captured.err == ""

    (line,) = [json.loads(x) for x in captured.out.splitlines() if x]
    assert line["event"] == "Exception in ASGI application"
    assert line["level"] == "error"
    assert "ValueError: kaboom" in line["exception"]


def test_log_level_filters(capsys: pytest.CaptureFixture[str]) -> None:
    configure_logging(make_settings(log_level="WARNING"))
    structlog.get_logger("t").info("dropped")
    structlog.get_logger("t").warning("kept")

    assert [line["event"] for line in _lines(capsys)] == ["kept"]


def test_bind_request_context(capsys: pytest.CaptureFixture[str]) -> None:
    configure_logging(make_settings())
    bind_request_context(tenant="acme")
    structlog.get_logger("t").info("work")

    (line,) = _lines(capsys)
    assert line["tenant"] == "acme"


def test_noisy_loggers_are_quieted() -> None:
    configure_logging(make_settings(log_level="DEBUG"))
    for name in ("sqlalchemy.engine", "uvicorn.access", "watchfiles"):
        assert logging.getLogger(name).level == logging.WARNING
