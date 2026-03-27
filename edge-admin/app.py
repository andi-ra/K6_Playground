from __future__ import annotations

import os
import shutil
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse

app = FastAPI(title="k6-playground-edge-admin", version="1.0.0")

CACHE_ROOT = Path(os.getenv("CACHE_ROOT", "/var/cache/nginx"))


def purge_cache(root: Path) -> int:
    removed = 0

    if not root.exists():
        return removed

    for entry in root.iterdir():
        if entry.name == "proxy_temp":
            continue
        if entry.is_dir():
            shutil.rmtree(entry)
            removed += 1
        else:
            entry.unlink()
            removed += 1

    return removed


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.api_route("/purge", methods=["PURGE", "POST"])
async def purge(request: Request) -> JSONResponse:
    if request.method not in {"PURGE", "POST"}:
        raise HTTPException(status_code=405, detail="method not allowed")

    removed = purge_cache(CACHE_ROOT)
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    return JSONResponse(
        status_code=200,
        content={
            "status": "purged",
            "removed_entries": removed,
            "cache_root": str(CACHE_ROOT),
        },
    )
