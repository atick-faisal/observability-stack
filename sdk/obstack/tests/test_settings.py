# Copyright (c) 2026 Atick Faisal
# SPDX-License-Identifier: MIT

from __future__ import annotations

import socket

import pytest

from conftest import make_settings
from obstack import ObservabilityConfigError, ObservabilitySettings


def test_missing_app_raises_config_error() -> None:
    with pytest.raises(ObservabilityConfigError, match="OBS_"):
        ObservabilitySettings.load()


def test_env_prefix_binds(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OBS_APP", "asset-management")
    monkeypatch.setenv("OBS_SERVICE", "worker")
    monkeypatch.setenv("OBS_ENV", "staging")
    monkeypatch.setenv("OBS_OTLP_ENDPOINT", "http://alloy:4317")

    settings = ObservabilitySettings.load()

    assert settings.app == "asset-management"
    assert settings.service == "worker"
    assert settings.env == "staging"
    assert settings.otlp_endpoint == "http://alloy:4317"


def test_service_name_and_identity() -> None:
    settings = make_settings()
    assert settings.service_name == "demo-api"
    assert settings.identity == {
        "app": "demo",
        "service": "api",
        "env": "production",
        "host": "test-host",
    }


def test_host_is_lowercased(monkeypatch: pytest.MonkeyPatch) -> None:
    assert make_settings(host="Ataghyfs-MacBook-Pro.local").host == "ataghyfs-macbook-pro.local"

    monkeypatch.setenv("OBS_APP", "demo")
    assert ObservabilitySettings.load().host == socket.gethostname().lower()


@pytest.mark.parametrize("value", ["Asset Management", "asset_management", "ASSET", ""])
def test_app_must_match_label_contract(value: str, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OBS_APP", value)
    with pytest.raises(ObservabilityConfigError):
        ObservabilitySettings.load()


@pytest.mark.parametrize("ratio", [-0.1, 1.1])
def test_sample_ratio_bounds(ratio: float) -> None:
    with pytest.raises(ValueError):
        make_settings(trace_sample_ratio=ratio)
