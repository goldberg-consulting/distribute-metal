from __future__ import annotations

from enum import Enum

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


class ProjectSpec(BaseModel):
    name: str
    root: str = "."
    working_dir: str = "."
    entrypoint: str
    include: list[str] = Field(default_factory=list)
    exclude: list[str] = Field(default_factory=list)


class PythonSpec(BaseModel):
    version: str
    pyproject: str
    lockfile: str = ""


class TorchrunSpec(BaseModel):
    nproc_per_node: int = 1
    master_port: int = 29500
    script_args: list[str] = Field(default_factory=list)


class Rank0OnlySpec(BaseModel):
    save_checkpoints: bool = True
    write_logs: bool = True


class TrainingSpec(BaseModel):
    backend: str
    torchrun: TorchrunSpec
    env: dict[str, str] = Field(default_factory=dict)
    checkpoint_dir: str = "checkpoints"
    rank0_only: Rank0OnlySpec = Field(default_factory=Rank0OnlySpec)


class DataSpec(BaseModel):
    name: str | None = None
    source: str
    url: str | None = None
    path: str
    sha256: str | None = None
    size_bytes: int | None = None
    unpack: str | None = None
    description: str | None = None


class SyncSpec(BaseModel):
    mode: str = "rsync-push"
    parallel_connections: int = 8
    chunk_size_mb: int = 64
    preferred_interface: str = "auto"


class CleanupSpec(BaseModel):
    delete_venv_on_success: bool = True
    delete_source_on_success: bool = True
    delete_data_on_success: bool = False
    retain_logs_days: int = 7


class ValidationSpec(BaseModel):
    require_arm64: bool = True
    min_free_disk_gb: int = 10
    required_tools: list[str] = Field(default_factory=list)
    check_firewall: bool = True


class JobSpec(BaseModel):
    version: int = 1
    project: ProjectSpec
    python: PythonSpec
    training: TrainingSpec
    data: list[DataSpec] = Field(default_factory=list)
    sync: SyncSpec = Field(default_factory=SyncSpec)
    cleanup: CleanupSpec = Field(default_factory=CleanupSpec)
    validation: ValidationSpec = Field(default_factory=ValidationSpec)


class JobInitRequest(BaseModel):
    job_id: str
    spec: JobSpec


class PrepareRequest(BaseModel):
    job_id: str


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


class SSHAuthorizeRequest(BaseModel):
    public_key: str
    key_name: str | None = None


class SSHAuthorizeResponse(BaseModel):
    ok: bool = True
    message: str | None = None
    ssh_user: str
    host_keys: list[str]
    receive_root: str
    rsync_available: bool


class BenchReceiverRequest(BaseModel):
    session_id: str
    max_bytes: int = Field(default=128 * 1024 * 1024, ge=1, le=256 * 1024 * 1024)


class BenchReceiverResponse(BaseModel):
    session_id: str
    port: int


class BenchSenderRequest(BaseModel):
    session_id: str
    host: str
    port: int
    bytes_to_send: int = Field(default=128 * 1024 * 1024, ge=1, le=256 * 1024 * 1024)
    chunk_size: int = Field(default=1024 * 1024, ge=4096, le=4 * 1024 * 1024)


class BenchSenderResponse(BaseModel):
    session_id: str
    bytes_sent: int
    duration_seconds: float
    throughput_mbps: float
    connect_latency_ms: float


class BenchResultState(str, Enum):
    pending = "pending"
    completed = "completed"
    failed = "failed"


class BenchResultResponse(BaseModel):
    session_id: str
    state: BenchResultState
    bytes_received: int = 0
    duration_seconds: float | None = None
    throughput_mbps: float | None = None
    error: str | None = None


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
