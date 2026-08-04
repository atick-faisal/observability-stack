from __future__ import annotations

import structlog

from obskit.settings import ObservabilitySettings

log = structlog.get_logger("obskit.errors")


def setup_error_reporting(settings: ObservabilitySettings) -> bool:
    if not settings.error_dsn:
        return False

    try:
        import sentry_sdk
    except ImportError:
        log.error('error reporting unavailable, install obskit["errors"]')
        return False

    # OTel owns tracing; Sentry is here for exception grouping only.
    sentry_sdk.init(
        dsn=settings.error_dsn,
        enable_tracing=False,
        shutdown_timeout=10,
        environment=settings.env,
        release=f"{settings.service_name}@{settings.version}",
    )
    return True
