from __future__ import annotations

from enum import Enum
from typing import Any

from pydantic import BaseModel, Field


class AgentState(str, Enum):
    idle = "idle"
    syncing = "syncing"
    provisioning = "provisioning"
    ready = "ready"
    launching = "launching"
    running = "running"
    failed = "failed"
    cleaned = "cleaned"


class PrepareRequest(BaseModel):
    job_id: str
    spec: dict[str, Any]


class LaunchRequest(BaseModel):
    job_id: str
    master_addr: str
    master_port: int = 29500
    world_size: int
    node_rank: int
    nproc_per_node: int = 1


class StopRequest(BaseModel):
    job_id: str


class CleanRequest(BaseModel):
    job_id: str


class AgentResponse(BaseModel):
    ok: bool
    message: str | None = None
    state: AgentState | None = None


class StatusResponse(BaseModel):
    state: AgentState
    job_id: str | None = None
    arch: str
    chip: str
    memory_gb: int
    macos_version: str
    agent_version: str
    mccl_version: str | None = None
    python_version: str | None = None
    uv_available: bool
    free_disk_gb: float
