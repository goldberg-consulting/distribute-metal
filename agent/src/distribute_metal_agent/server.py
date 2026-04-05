"""DistributeMetal agent HTTP server.

Run with:
    uv run distribute-metal-agent
    # or
    uvicorn distribute_metal_agent.server:app --host 0.0.0.0 --port 8477
"""
from __future__ import annotations

import asyncio
import logging
import threading
from contextlib import asynccontextmanager
from pathlib import Path

import uvicorn
from fastapi import FastAPI, HTTPException

from . import __version__
from .models import (
    AgentResponse,
    AgentState,
    CleanRequest,
    LaunchRequest,
    PrepareRequest,
    StatusResponse,
    StopRequest,
)
from .runner import is_running, launch_torchrun, poll_exit_code, read_logs, stop_job
from .sysinfo import (
    get_arch,
    get_chip,
    get_free_disk_gb,
    get_macos_version,
    get_mccl_version,
    get_memory_gb,
    get_python_version,
    get_uv_available,
)
from .workspace import clean_workspace, ensure_workspace, provision_venv

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
logger = logging.getLogger("distribute-metal-agent")

state = AgentState.idle
current_job_id: str | None = None
_provision_threads: dict[str, threading.Thread] = {}


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("DistributeMetal agent v%s starting on port 8477", __version__)
    yield
    logger.info("Agent shutting down")


app = FastAPI(title="DistributeMetal Agent", version=__version__, lifespan=lifespan)


@app.get("/status")
async def status() -> StatusResponse:
    global state, current_job_id

    if current_job_id and state == AgentState.running:
        if not is_running(current_job_id):
            code = poll_exit_code(current_job_id)
            state = AgentState.ready if code == 0 else AgentState.failed

    return StatusResponse(
        state=state,
        job_id=current_job_id,
        arch=get_arch(),
        chip=get_chip(),
        memory_gb=get_memory_gb(),
        macos_version=get_macos_version(),
        agent_version=__version__,
        mccl_version=get_mccl_version(),
        python_version=get_python_version(),
        uv_available=get_uv_available(),
        free_disk_gb=get_free_disk_gb(),
    )


@app.post("/jobs/prepare")
async def prepare(req: PrepareRequest) -> AgentResponse:
    global state, current_job_id

    if state not in (AgentState.idle, AgentState.failed, AgentState.cleaned):
        raise HTTPException(400, f"Cannot prepare: agent is {state.value}")

    current_job_id = req.job_id
    state = AgentState.syncing

    try:
        ensure_workspace(req.job_id)
    except Exception as exc:
        state = AgentState.failed
        return AgentResponse(ok=False, message=str(exc), state=state)

    def _provision():
        global state
        try:
            state = AgentState.provisioning
            provision_venv(req.job_id)
            state = AgentState.ready
        except Exception as exc:
            logger.exception("Provisioning failed for job %s", req.job_id)
            state = AgentState.failed

    t = threading.Thread(target=_provision, daemon=True)
    t.start()
    _provision_threads[req.job_id] = t

    return AgentResponse(ok=True, message="Preparing", state=state)


@app.post("/jobs/launch")
async def launch(req: LaunchRequest) -> AgentResponse:
    global state, current_job_id

    if state != AgentState.ready:
        raise HTTPException(400, f"Cannot launch: agent is {state.value}, expected ready")

    if current_job_id != req.job_id:
        raise HTTPException(400, "Job ID mismatch")

    state = AgentState.launching

    try:
        spec = {}  # Full spec would be loaded from workspace manifest
        launch_torchrun(
            job_id=req.job_id,
            entrypoint="train.py",
            master_addr=req.master_addr,
            master_port=req.master_port,
            world_size=req.world_size,
            node_rank=req.node_rank,
            nproc_per_node=req.nproc_per_node,
        )
        state = AgentState.running
        return AgentResponse(ok=True, message="Launched", state=state)
    except Exception as exc:
        state = AgentState.failed
        return AgentResponse(ok=False, message=str(exc), state=state)


@app.post("/jobs/stop")
async def stop(req: StopRequest) -> AgentResponse:
    global state

    stop_job(req.job_id)
    state = AgentState.idle
    return AgentResponse(ok=True, message="Stopped", state=state)


@app.get("/jobs/{job_id}/logs")
async def logs(job_id: str, tail: int = 200) -> list[str]:
    return read_logs(job_id, tail=tail)


@app.post("/jobs/clean")
async def clean(req: CleanRequest) -> AgentResponse:
    global state, current_job_id

    stop_job(req.job_id)
    clean_workspace(req.job_id)
    state = AgentState.cleaned
    current_job_id = None
    return AgentResponse(ok=True, message="Cleaned", state=state)


@app.put("/jobs/{job_id}/bundle")
async def upload_bundle(job_id: str):
    """Placeholder for bundle upload. V1 expects the project to be
    pre-synced to the workspace or fetched from the coordinator file server."""
    raise HTTPException(501, "Bundle upload not yet implemented — use coordinator file server")


def main():
    uvicorn.run(
        "distribute_metal_agent.server:app",
        host="0.0.0.0",
        port=8477,
        log_level="info",
    )


if __name__ == "__main__":
    main()
