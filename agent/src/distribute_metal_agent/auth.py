"""Shared-secret authentication for the distribute-metal agent.

The cluster token is read from (in priority order):
  1. DISTRIBUTE_METAL_TOKEN environment variable
  2. ~/.config/distribute-metal/token file (first line, stripped)

If neither is set, the agent runs without authentication and logs a warning.
All POST/PUT endpoints require a matching Authorization: Bearer <token> header.
GET /status is unauthenticated so Bonjour probes work without credentials.
"""
from __future__ import annotations

import logging
import os
from pathlib import Path

from fastapi import Request, HTTPException
from starlette.middleware.base import BaseHTTPMiddleware, RequestResponseEndpoint
from starlette.responses import Response

logger = logging.getLogger("distribute-metal-agent")

TOKEN_FILE = Path.home() / ".config" / "distribute-metal" / "token"
OPEN_PATHS = {"/status", "/docs", "/openapi.json"}
OPEN_METHODS = {"GET"}


def load_token() -> str | None:
    token = os.environ.get("DISTRIBUTE_METAL_TOKEN")
    if token:
        return token.strip()

    if TOKEN_FILE.exists():
        text = TOKEN_FILE.read_text().strip().splitlines()
        if text:
            return text[0].strip()

    return None


class AuthMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, token: str | None):
        super().__init__(app)
        self.token = token

    async def dispatch(self, request: Request, call_next: RequestResponseEndpoint) -> Response:
        if self.token is None:
            return await call_next(request)

        if request.method in OPEN_METHODS and request.url.path in OPEN_PATHS:
            return await call_next(request)

        if request.url.path == f"/jobs/{request.path_params.get('job_id', '')}/logs" and request.method == "GET":
            return await call_next(request)

        auth = request.headers.get("authorization", "")
        if not auth.startswith("Bearer "):
            raise HTTPException(401, "Missing Authorization: Bearer <token> header")

        provided = auth[7:].strip()
        if provided != self.token:
            raise HTTPException(403, "Invalid token")

        return await call_next(request)
