# Build context is the repo root; see demo/app/Dockerfile.
#
#   docker build -f demo/loadgen/Dockerfile .
FROM python:3.13-slim

COPY --from=ghcr.io/astral-sh/uv:0.12.0 /uv /bin/uv

ENV PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PATH="/src/demo/loadgen/.venv/bin:$PATH"

WORKDIR /src/demo/loadgen

COPY sdk/obstack /src/sdk/obstack
COPY demo/loadgen/pyproject.toml demo/loadgen/uv.lock ./

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev

COPY demo/loadgen/main.py ./

RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin demo
USER demo

EXPOSE 9101

CMD ["python", "main.py"]
