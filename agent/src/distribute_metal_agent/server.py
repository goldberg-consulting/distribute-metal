"""measured.one.distribute-metal agent HTTP server.

Run with:
    uv run distribute-metal-agent
    # or
    uvicorn distribute_metal_agent.server:app --host 0.0.0.0 --port 8477
"""
from __future__ import annotations

import logging
import sys
import threading
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, HTTPException

from . import __version__
from .bench import get_result, run_sender, start_receiver
from .models import (
    AgentResponse,
    AgentState,
    BenchReceiverRequest,
    BenchReceiverResponse,
    BenchResultResponse,
    BenchSenderRequest,
    BenchSenderResponse,
    CleanRequest,
    JobInitRequest,
    LaunchRequest,
    PrepareRequest,
    SSHAuthorizeRequest,
    SSHAuthorizeResponse,
    StatusResponse,
    StopRequest,
)
from .runner import is_running, launch_torchrun, poll_exit_code, read_logs, stop_job
from .ssh_setup import authorize_public_key, current_ssh_user, host_public_keys, rsync_available
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
from .auth import AuthMiddleware, load_token
from .workspace import (
    clean_workspace,
    initialize_job_workspace,
    load_job_spec,
    promote_incoming,
    provision_venv,
    receive_root,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
logger = logging.getLogger("distribute-metal-agent")

state = AgentState.idle
current_job_id: str | None = None
_provision_threads: dict[str, threading.Thread] = {}


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("measured.one.distribute-metal agent v%s starting on port 8477", __version__)
    yield
    logger.info("Agent shutting down")


app = FastAPI(title="measured.one.distribute-metal Agent", version=__version__, lifespan=lifespan)

_token = load_token()
if _token:
    app.add_middleware(AuthMiddleware, token=_token)
    logger.info("Authentication enabled (token loaded)")
else:
    logger.warning(
        "No cluster token found. Agent is running WITHOUT authentication. "
        "Set DISTRIBUTE_METAL_TOKEN or create ~/.config/distribute-metal/token"
    )


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


@app.post("/jobs/init")
async def init_job(req: JobInitRequest) -> AgentResponse:
    global state, current_job_id

    if state not in (AgentState.idle, AgentState.failed, AgentState.cleaned):
        raise HTTPException(400, f"Cannot initialize job: agent is {state.value}")

    current_job_id = req.job_id
    state = AgentState.syncing

    try:
        initialize_job_workspace(req.job_id, req.spec)
    except Exception as exc:
        state = AgentState.failed
        return AgentResponse(ok=False, message=str(exc), state=state)

    return AgentResponse(ok=True, message="Initialized for sync", state=state)


@app.post("/jobs/prepare")
async def prepare(req: PrepareRequest) -> AgentResponse:
    global state, current_job_id

    if current_job_id != req.job_id:
        raise HTTPException(400, "Job ID mismatch")
    if state != AgentState.syncing:
        raise HTTPException(400, f"Cannot prepare: agent is {state.value}")

    try:
        promote_incoming(req.job_id)
    except Exception as exc:
        state = AgentState.failed
        return AgentResponse(ok=False, message=str(exc), state=state)

    state = AgentState.provisioning

    def _provision():
        global state
        try:
            provision_venv(req.job_id)
            state = AgentState.ready
        except Exception as exc:
            logger.exception("Provisioning failed for job %s", req.job_id)
            state = AgentState.failed

    t = threading.Thread(target=_provision, daemon=True)
    t.start()
    _provision_threads[req.job_id] = t

    return AgentResponse(ok=True, message="Provisioning", state=state)


@app.post("/jobs/launch")
async def launch(req: LaunchRequest) -> AgentResponse:
    global state, current_job_id

    if state != AgentState.ready:
        raise HTTPException(400, f"Cannot launch: agent is {state.value}, expected ready")

    if current_job_id != req.job_id:
        raise HTTPException(400, "Job ID mismatch")

    state = AgentState.launching

    try:
        spec = load_job_spec(req.job_id)
        launch_torchrun(
            job_id=req.job_id,
            entrypoint=spec.project.entrypoint,
            master_addr=req.master_addr,
            master_port=req.master_port,
            world_size=req.world_size,
            node_rank=req.node_rank,
            nproc_per_node=req.nproc_per_node,
            script_args=spec.training.torchrun.script_args,
            env_overrides=spec.training.env,
            working_dir=spec.project.working_dir if spec.project.working_dir != "." else None,
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


@app.post("/ssh/authorize")
async def authorize_ssh(req: SSHAuthorizeRequest) -> SSHAuthorizeResponse:
    authorize_public_key(
        public_key=req.public_key,
        key_name=req.key_name,
        receive_root=receive_root(),
        python_executable=sys.executable,
    )
    return SSHAuthorizeResponse(
        message="SSH key authorized for push sync",
        ssh_user=current_ssh_user(),
        host_keys=host_public_keys(),
        receive_root=str(receive_root()),
        rsync_available=rsync_available(),
    )


def _ensure_bench_available() -> None:
    if state in (AgentState.syncing, AgentState.provisioning, AgentState.launching, AgentState.running):
        raise HTTPException(400, f"Cannot run benchmark while agent is {state.value}")


@app.post("/diag/bench/receiver", response_model=BenchReceiverResponse)
async def bench_receiver(req: BenchReceiverRequest) -> BenchReceiverResponse:
    _ensure_bench_available()
    try:
        port = start_receiver(req.session_id, req.max_bytes)
    except Exception as exc:
        raise HTTPException(400, str(exc)) from exc
    return BenchReceiverResponse(session_id=req.session_id, port=port)


@app.post("/diag/bench/sender", response_model=BenchSenderResponse)
async def bench_sender(req: BenchSenderRequest) -> BenchSenderResponse:
    _ensure_bench_available()
    try:
        return run_sender(
            session_id=req.session_id,
            host=req.host,
            port=req.port,
            bytes_to_send=req.bytes_to_send,
            chunk_size=req.chunk_size,
        )
    except Exception as exc:
        raise HTTPException(400, str(exc)) from exc


@app.get("/diag/bench/{session_id}", response_model=BenchResultResponse)
async def bench_result(session_id: str) -> BenchResultResponse:
    try:
        return get_result(session_id)
    except KeyError as exc:
        raise HTTPException(404, "Benchmark session not found") from exc


@app.put("/jobs/{job_id}/bundle")
async def upload_bundle(job_id: str):
    """Placeholder for bundle upload. V1 expects the project to be
    pre-synced to the workspace or fetched from the coordinator file server."""
    raise HTTPException(501, "Bundle upload not implemented. Use SSH/rsync sync.")


def main():
    uvicorn.run(
        "distribute_metal_agent.server:app",
        host="0.0.0.0",
        port=8477,
        log_level="info",
    )


if __name__ == "__main__":
    main()
