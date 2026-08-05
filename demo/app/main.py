from __future__ import annotations

import asyncio
import os
import random
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

import structlog
from fastapi import FastAPI
from obstack import bind_request_context, setup_observability
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

log = structlog.get_logger("demo")

DATABASE_URL = os.environ.get(
    "DATABASE_URL", "postgresql+asyncpg://demo:demo@demo-db:5432/demo"
)

_DDL = """
CREATE TABLE IF NOT EXISTS demo_events (
    id          bigserial PRIMARY KEY,
    kind        text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
)
"""


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    async with engine.begin() as conn:
        await conn.execute(text(_DDL))
    log.info("demo app ready", database=engine.url.render_as_string(hide_password=True))
    try:
        yield
    finally:
        await engine.dispose()
        # Without this the BatchSpanProcessor drops whatever it has not exported
        # yet, so the last few seconds of traces vanish on every redeploy.
        obs.shutdown()


engine: AsyncEngine = create_async_engine(DATABASE_URL, pool_size=5, max_overflow=5)
app = FastAPI(title="obstack demo", lifespan=lifespan)

# /health is excluded, so the orchestrator's probe traffic never reaches a metric
# label or a log line. Everything else is instrumented.
obs = setup_observability(app, engine=engine, excluded_paths=["/health"])


@app.get("/health", include_in_schema=False)
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/ok")
async def ok() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/items/{item_id}")
async def read_item(item_id: int) -> dict[str, Any]:
    # The metric label is route="/items/{item_id}", never "/items/7" — the raw
    # path would mint one series per id. See docs/labels.md §4.3.
    bind_request_context(item_id=item_id)
    return {"item_id": item_id, "name": f"item-{item_id}"}


@app.get("/slow")
async def slow() -> dict[str, float]:
    delay = random.uniform(0.2, 1.5)
    await asyncio.sleep(delay)
    return {"slept_s": round(delay, 3)}


@app.get("/boom")
async def boom() -> dict[str, str]:
    raise ValueError("demo failure")


@app.get("/db")
async def db() -> dict[str, int]:
    async with engine.begin() as conn:
        await conn.execute(text("INSERT INTO demo_events (kind) VALUES ('demo')"))
        total = await conn.scalar(text("SELECT count(*) FROM demo_events"))
    return {"events": int(total or 0)}
