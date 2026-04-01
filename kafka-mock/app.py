from __future__ import annotations

from collections import deque
from datetime import datetime, timezone
import json
import socket
from typing import Any

from fastapi import FastAPI, Request

app = FastAPI(title="k6-playground-kafka-mock", version="1.0.0")

HOSTNAME = socket.gethostname()
EVENTS: deque[dict[str, Any]] = deque(maxlen=500)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/events")
async def ingest_event(request: Request) -> dict[str, Any]:
    payload = await request.json()
    event = {
        "received_at": datetime.now(timezone.utc).isoformat(),
        "host": HOSTNAME,
        "payload": payload,
    }
    EVENTS.append(event)
    print(json.dumps(event), flush=True)
    return {"status": "accepted", "events_buffered": len(EVENTS)}


@app.get("/events")
def list_events(limit: int = 20) -> dict[str, Any]:
    limit = max(1, min(limit, len(EVENTS) or 1))
    return {
        "count": len(EVENTS),
        "items": list(EVENTS)[-limit:],
    }
