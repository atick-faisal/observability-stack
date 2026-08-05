from __future__ import annotations

import structlog

from obstack.settings import ObservabilitySettings

log = structlog.get_logger("obstack.errors")


def setup_error_reporting(settings: ObservabilitySettings) -> bool:
    if not settings.error_dsn:
        return False

    try:
        import sentry_sdk
    except ImportError:
        log.error('error reporting unavailable, install obstack["errors"]')
        return False

    # OTel owns tracing; Sentry is here for exception grouping only.
    sentry_sdk.init(
        dsn=settings.error_dsn,
        enable_tracing=False,
        shutdown_timeout=10,
        environment=settings.env,
        release=f"{settings.service_name}@{settings.version}",
        # Defaults to socket.gethostname(), which in a container is its short ID —
        # a different value from the `host` label on this service's metrics, logs
        # and traces, and one that changes on every recreate. Passing OBS_HOST makes
        # the error's server_name tag the same string you filter the dashboards by.
        server_name=settings.host,
    )
    return True
