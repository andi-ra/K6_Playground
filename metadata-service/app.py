from __future__ import annotations

import hashlib
import socket
from typing import Any

from fastapi import FastAPI

app = FastAPI(title="k6-playground-metadata", version="1.0.0")

HOSTNAME = socket.gethostname()


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/metadata")
def metadata(
    tenant: str = "demo",
    title: str = "movie1",
    variant: str = "720p",
    region: str = "us",
    target_kind: str = "lua_policy",
) -> dict[str, Any]:
    metadata_key = ":".join([tenant, title, variant, region, target_kind])
    metadata_id = hashlib.sha256(metadata_key.encode("utf-8")).hexdigest()[:16]
    bitrate_profile = {
        "540p": {"codec": "h264", "estimated_kbps": 1800},
        "720p": {"codec": "h264", "estimated_kbps": 3500},
        "1080p": {"codec": "h264", "estimated_kbps": 6200},
    }.get(variant, {"codec": "h264", "estimated_kbps": 2500})

    return {
        "metadata_id": metadata_id,
        "tenant": tenant,
        "title": title,
        "variant": variant,
        "region": region,
        "target_kind": target_kind,
        "source": "metadata-service",
        "edge_cache_hint": "private" if region == "eu" else "public",
        "policy_tags": [tenant, region, target_kind],
        "profile": bitrate_profile,
        "served_by": HOSTNAME,
    }
