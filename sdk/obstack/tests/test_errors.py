# Copyright (c) 2026 Atick Faisal
# SPDX-License-Identifier: MIT

from __future__ import annotations

from typing import Any

import pytest

from conftest import make_settings
from obstack.errors import setup_error_reporting


def test_no_dsn_is_not_an_error() -> None:
    assert setup_error_reporting(make_settings()) is False


def test_init_carries_the_label_contract(monkeypatch: pytest.MonkeyPatch) -> None:
    sentry_sdk = pytest.importorskip("sentry_sdk")
    captured: dict[str, Any] = {}
    monkeypatch.setattr(sentry_sdk, "init", lambda **kwargs: captured.update(kwargs))

    assert setup_error_reporting(make_settings(error_dsn="http://key@localhost:8000/1")) is True

    assert captured["environment"] == "production"
    assert captured["release"] == "demo-api@1.2.3"
    # Not socket.gethostname(): the same string the metrics, logs and traces carry
    # as `host`, so an error can be traced back to the box it happened on.
    assert captured["server_name"] == "test-host"
    # OTel owns tracing.
    assert captured["enable_tracing"] is False
