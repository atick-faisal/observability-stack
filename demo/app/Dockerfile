# Build context is the repo root, and the host layout is mirrored inside the
# image, so `obskit = { path = "../../sdk/obskit" }` resolves in both places.
#
#   docker build -f demo/app/Dockerfile .
FROM python:3.13-slim

COPY --from=ghcr.io/astral-sh/uv:0.12.0 /uv /bin/uv

ENV PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PATH="/src/demo/app/.venv/bin:$PATH"

WORKDIR /src/demo/app

# The SDK first: it is a path dependency, so it has to exist before uv can
# resolve. Copying it separately keeps app source edits off this layer.
COPY sdk/obskit /src/sdk/obskit
COPY demo/app/pyproject.toml demo/app/uv.lock ./

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev

COPY demo/app/main.py ./

RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin demo
USER demo

EXPOSE 8000

# One worker, deliberately. Each uvicorn worker holds its own CollectorRegistry;
# with several behind one socket, consecutive scrapes hit different workers and a
# counter appears to move backwards, which Prometheus reads as a reset. Scale by
# running more containers, or set PROMETHEUS_MULTIPROC_DIR.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
