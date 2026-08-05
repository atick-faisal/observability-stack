from __future__ import annotations

import json

import pytest
from fastapi import FastAPI
from prometheus_client.openmetrics.parser import text_string_to_metric_families
from starlette.testclient import TestClient

from conftest import make_settings
from obstack import setup_observability


def build_app(**overrides: object) -> tuple[FastAPI, TestClient]:
    app = FastAPI()

    @app.get("/ok")
    def ok() -> dict[str, bool]:
        return {"ok": True}

    @app.get("/items/{item_id}")
    def item(item_id: int) -> dict[str, int]:
        return {"item_id": item_id}

    @app.get("/boom")
    def boom() -> None:
        raise ValueError("kaboom")

    setup_observability(app, settings=make_settings(**overrides))
    return app, TestClient(app, raise_server_exceptions=False)


def scrape(client: TestClient) -> str:
    response = client.get("/metrics")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("application/openmetrics-text")
    return response.text


def labels_of(body: str, metric: str) -> list[dict[str, str]]:
    return [
        sample.labels
        for family in text_string_to_metric_families(body)
        for sample in family.samples
        if sample.name == metric
    ]


def test_route_pattern_not_raw_path() -> None:
    _, client = build_app()
    assert client.get("/items/7").status_code == 200

    body = scrape(client)
    assert 'route="/items/{item_id}"' in body
    assert "/items/7" not in body


def test_identity_labels_on_every_series() -> None:
    _, client = build_app(app="alpha", service="worker", env="staging")
    client.get("/ok")

    for line in scrape(client).splitlines():
        if line.startswith("fastapi_") and "fastapi_app_info" not in line:
            assert 'app="alpha"' in line
            assert 'service="worker"' in line
            assert 'env="staging"' in line


def test_unhandled_exception_counts_as_500() -> None:
    _, client = build_app()
    assert client.get("/boom").status_code == 500

    body = scrape(client)
    assert {"route": "/boom", "exception_type": "ValueError"}.items() <= (
        labels_of(body, "fastapi_exceptions_total")[0].items()
    )
    assert {"route": "/boom", "status_code": "500"}.items() <= (
        labels_of(body, "fastapi_requests_total")[0].items()
    )


def test_unmatched_route_collapses_to_empty() -> None:
    _, client = build_app()
    assert client.get("/nope/12345").status_code == 404

    body = scrape(client)
    assert {"route": "", "status_code": "404"}.items() <= (
        labels_of(body, "fastapi_requests_total")[0].items()
    )
    assert "12345" not in body


def test_metrics_path_is_excluded() -> None:
    _, client = build_app()
    scrape(client)
    assert 'route="/metrics"' not in scrape(client)


def test_excluded_paths_parameter() -> None:
    app = FastAPI()

    @app.get("/health")
    def health() -> dict[str, bool]:
        return {"ok": True}

    setup_observability(app, settings=make_settings(), excluded_paths=("/health",))
    client = TestClient(app)
    client.get("/health")

    assert 'route="/health"' not in client.get("/metrics").text


def test_two_apps_in_one_process() -> None:
    _, first = build_app(app="alpha")
    _, second = build_app(app="beta")

    first.get("/ok")
    second.get("/ok")

    assert 'app="alpha"' in scrape(first)
    assert 'app="alpha"' not in scrape(second)
    assert 'app="beta"' in scrape(second)


def test_request_log_line(capsys: pytest.CaptureFixture[str]) -> None:
    _, client = build_app()
    capsys.readouterr()
    client.get("/items/7")

    lines = [
        json.loads(line)
        for line in capsys.readouterr().out.splitlines()
        if line.startswith("{")
    ]
    http = next(line for line in lines if line["event"] == "HTTP")
    assert http["method"] == "GET"
    assert http["path"] == "/items/7"
    assert http["route"] == "/items/{item_id}"
    assert http["status_code"] == 200
    assert http["level"] == "info"


def test_metrics_disabled() -> None:
    app = FastAPI()

    @app.get("/ok")
    def ok() -> dict[str, bool]:
        return {"ok": True}

    setup_observability(app, settings=make_settings(metrics_enabled=False))
    client = TestClient(app)

    assert client.get("/ok").status_code == 200
    assert client.get("/metrics").status_code == 404


def test_observability_handle() -> None:
    app = FastAPI()
    obs = setup_observability(app, settings=make_settings())

    assert obs.settings.service_name == "demo-api"
    assert obs.tracer_provider is None
    obs.shutdown()
