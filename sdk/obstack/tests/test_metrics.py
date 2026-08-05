from __future__ import annotations

from prometheus_client.parser import text_string_to_metric_families

from conftest import make_settings
from obstack.metrics import build_metrics, render


def test_registries_are_isolated() -> None:
    a = build_metrics(make_settings(app="alpha"))
    b = build_metrics(make_settings(app="beta"))

    assert a.registry is not b.registry

    a_body, _ = render(a.registry)
    b_body, _ = render(b.registry)
    assert 'app="alpha"' in a_body.decode()
    assert 'app="alpha"' not in b_body.decode()


def test_openmetrics_exposition() -> None:
    metrics = build_metrics(make_settings())
    metrics.requests.labels(
        app="demo", service="api", env="production", method="GET", route="/ok", status_code="200"
    ).inc()

    body, content_type = render(metrics.registry)
    text = body.decode()

    assert content_type.startswith("application/openmetrics-text")
    assert "# TYPE fastapi_requests counter" in text
    assert text.endswith("# EOF\n")


def test_app_info_carries_identity_and_version() -> None:
    metrics = build_metrics(make_settings(version="9.9.9"))
    body, _ = render(metrics.registry)

    samples = {
        sample.name: sample.labels
        for family in text_string_to_metric_families(body.decode())
        for sample in family.samples
    }
    assert samples["fastapi_app_info"] == {
        "app": "demo",
        "service": "api",
        "env": "production",
        "version": "9.9.9",
    }


def test_no_created_series() -> None:
    metrics = build_metrics(make_settings())
    metrics.requests.labels(
        app="demo", service="api", env="production", method="GET", route="/ok", status_code="200"
    ).inc()

    body, _ = render(metrics.registry)
    assert "_created" not in body.decode()


def test_metric_names_are_app_independent() -> None:
    body, _ = render(build_metrics(make_settings(app="asset-management")).registry)
    for line in body.decode().splitlines():
        if line.startswith("# TYPE "):
            assert "asset" not in line.split()[2]
