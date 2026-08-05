from __future__ import annotations

import json
import os

import pytest
from fastapi import FastAPI
from opentelemetry.sdk.trace.export import SpanExporter
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from starlette.testclient import TestClient

from conftest import make_settings
from obstack import setup_observability
from obstack.settings import ObservabilitySettings
from obstack.tracing import apply_semconv_opt_in, build_resource, build_tracer_provider


def test_resource_carries_flat_and_semconv_names() -> None:
    attributes = build_resource(make_settings()).attributes

    assert attributes["app"] == "demo"
    assert attributes["service"] == "api"
    assert attributes["env"] == "production"
    assert attributes["host"] == "test-host"
    assert attributes["service.name"] == "demo-api"
    assert attributes["service.version"] == "1.2.3"
    assert attributes["deployment.environment.name"] == "production"


def test_stable_http_semconv_is_opted_into(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("OTEL_SEMCONV_STABILITY_OPT_IN", raising=False)

    build_tracer_provider(make_settings())

    assert os.environ["OTEL_SEMCONV_STABILITY_OPT_IN"] == "http"


def test_explicit_semconv_opt_in_is_not_overridden(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OTEL_SEMCONV_STABILITY_OPT_IN", "http/dup")

    apply_semconv_opt_in()

    assert os.environ["OTEL_SEMCONV_STABILITY_OPT_IN"] == "http/dup"


def test_no_endpoint_disables_tracing() -> None:
    assert build_tracer_provider(make_settings()) is None


def test_exporter_failure_degrades_to_no_tracing(monkeypatch: pytest.MonkeyPatch) -> None:
    def explode(_settings: ObservabilitySettings) -> SpanExporter:
        raise OSError("no route to host")

    monkeypatch.setattr("obstack.tracing._build_exporter", explode)

    assert build_tracer_provider(make_settings(otlp_endpoint="http://alloy:4317")) is None


def test_span_correlates_with_log_line_and_exemplar(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    exporter = InMemorySpanExporter()
    monkeypatch.setattr("obstack.tracing._build_exporter", lambda _settings: exporter)

    app = FastAPI()

    @app.get("/items/{item_id}")
    def item(item_id: int) -> dict[str, int]:
        return {"item_id": item_id}

    obs = setup_observability(
        app, settings=make_settings(otlp_endpoint="http://alloy:4317")
    )
    client = TestClient(app)

    capsys.readouterr()
    assert client.get("/items/7").status_code == 200
    metrics = client.get("/metrics").text
    output = capsys.readouterr().out
    obs.shutdown()

    spans = exporter.get_finished_spans()
    assert [s.name for s in spans] == ["GET /items/{item_id}"]
    trace_id = format(spans[0].context.trace_id, "032x")

    http = next(
        line
        for line in (json.loads(x) for x in output.splitlines() if x.startswith("{"))
        if line["event"] == "HTTP"
    )
    assert http["trace_id"] == trace_id

    exemplars = [line for line in metrics.splitlines() if "# {trace_id=" in line]
    assert exemplars
    assert all(f'trace_id="{trace_id}"' in line for line in exemplars)
