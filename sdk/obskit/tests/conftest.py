from __future__ import annotations

import logging
from collections.abc import Iterator

import pytest
import structlog

from obskit import ObservabilitySettings


@pytest.fixture(autouse=True)
def clean_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for key in list(__import__("os").environ):
        if key.startswith("OBS_"):
            monkeypatch.delenv(key, raising=False)


@pytest.fixture(autouse=True)
def reset_logging() -> Iterator[None]:
    yield
    structlog.reset_defaults()
    root = logging.getLogger()
    root.handlers.clear()


def make_settings(**overrides: object) -> ObservabilitySettings:
    defaults: dict[str, object] = {
        "app": "demo",
        "service": "api",
        "env": "production",
        "host": "test-host",
        "version": "1.2.3",
    }
    return ObservabilitySettings(**{**defaults, **overrides})  # type: ignore[arg-type]
