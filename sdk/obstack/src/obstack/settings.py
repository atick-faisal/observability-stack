# Copyright (c) 2026 Atick Faisal
# SPDX-License-Identifier: MIT

from __future__ import annotations

import socket
from typing import Literal

from pydantic import Field, ValidationError, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class ObservabilityConfigError(RuntimeError): ...


class ObservabilitySettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="OBS_", extra="ignore")

    app: str = Field(pattern=r"^[a-z0-9-]+$")
    service: str = Field(default="api", pattern=r"^[a-z0-9-]+$")
    env: Literal["local", "staging", "production"] = "local"
    host: str = Field(default_factory=socket.gethostname)
    version: str = "0.0.0"
    log_level: str = "INFO"
    log_format: Literal["auto", "json", "console"] = "auto"
    otlp_endpoint: str | None = None
    otlp_protocol: Literal["grpc", "http"] = "grpc"
    trace_sample_ratio: float = Field(default=1.0, ge=0.0, le=1.0)
    metrics_enabled: bool = True
    metrics_path: str = Field(default="/metrics", pattern=r"^/")
    error_dsn: str | None = None

    @field_validator("host")
    @classmethod
    def _normalize_host(cls, value: str) -> str:
        return value.lower()

    @property
    def service_name(self) -> str:
        return f"{self.app}-{self.service}"

    @property
    def identity(self) -> dict[str, str]:
        return {"app": self.app, "service": self.service, "env": self.env, "host": self.host}

    @classmethod
    def load(cls) -> ObservabilitySettings:
        try:
            # Every field is env-populated, but pydantic-settings' generated __init__
            # still declares them required and pyright has no plugin to know better.
            return cls()  # pyright: ignore[reportCallIssue]
        except ValidationError as exc:
            raise ObservabilityConfigError(
                f"invalid observability configuration (OBS_* environment variables):\n{exc}"
            ) from exc
