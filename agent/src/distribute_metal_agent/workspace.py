"""Workspace management for the worker agent.

Each job lives under ``WORKSPACE_ROOT/<job_id>``. Sync first lands in
``incoming/`` and is only promoted into live ``src`` and ``data`` once the
coordinator has finished pushing files for that job.
"""

from __future__ import annotations

import json
import logging
import shutil
import subprocess
from pathlib import Path

from .models import JobSpec

logger = logging.getLogger(__name__)

WORKSPACE_ROOT = Path.home() / "Library" / "Application Support" / "DistributeMetal" / "jobs"
SPEC_FILE = "job_spec.json"
INCOMING_DIR = "incoming"


def job_dir(job_id: str) -> Path:
    return WORKSPACE_ROOT / job_id


def receive_root() -> Path:
    WORKSPACE_ROOT.mkdir(parents=True, exist_ok=True)
    return WORKSPACE_ROOT


def incoming_dir(job_id: str) -> Path:
    return job_dir(job_id) / INCOMING_DIR


def incoming_src_dir(job_id: str) -> Path:
    return incoming_dir(job_id) / "src"


def incoming_data_dir(job_id: str) -> Path:
    return incoming_dir(job_id) / "data"


def ensure_workspace(job_id: str) -> Path:
    d = job_dir(job_id)
    (d / "src").mkdir(parents=True, exist_ok=True)
    (d / "data").mkdir(exist_ok=True)
    (d / "logs").mkdir(exist_ok=True)
    return d


def initialize_job_workspace(job_id: str, spec: JobSpec) -> Path:
    d = ensure_workspace(job_id)
    incoming = incoming_dir(job_id)
    if incoming.exists():
        shutil.rmtree(incoming)
    incoming_src_dir(job_id).mkdir(parents=True, exist_ok=True)
    incoming_data_dir(job_id).mkdir(parents=True, exist_ok=True)
    save_job_spec(job_id, spec)
    return d


def save_job_spec(job_id: str, spec: JobSpec) -> None:
    d = ensure_workspace(job_id)
    (d / SPEC_FILE).write_text(spec.model_dump_json(indent=2), encoding="utf8")


def load_job_spec(job_id: str) -> JobSpec:
    spec_path = job_dir(job_id) / SPEC_FILE
    if not spec_path.exists():
        raise FileNotFoundError(f"No job spec found for {job_id}")
    return JobSpec.model_validate(json.loads(spec_path.read_text(encoding="utf8")))


def promote_incoming(job_id: str) -> None:
    d = ensure_workspace(job_id)
    incoming_src = incoming_src_dir(job_id)
    if not incoming_src.exists():
        raise FileNotFoundError(f"No synced source found in {incoming_src}")

    incoming_data = incoming_data_dir(job_id)

    for subdir in ["src", "data"]:
        path = d / subdir
        if path.exists():
            shutil.rmtree(path)

    incoming_src.rename(d / "src")
    if incoming_data.exists():
        incoming_data.rename(d / "data")
    else:
        (d / "data").mkdir(parents=True, exist_ok=True)

    incoming = incoming_dir(job_id)
    if incoming.exists():
        shutil.rmtree(incoming)


def provision_venv(job_id: str) -> None:
    """Run uv sync --frozen inside the job workspace."""
    d = job_dir(job_id)
    src = d / "src"

    pyproject = src / "pyproject.toml"
    if not pyproject.exists():
        raise FileNotFoundError(f"No pyproject.toml in {src}")

    logger.info("Provisioning venv for job %s", job_id)

    subprocess.run(
        ["uv", "venv", str(d / ".venv")],
        cwd=str(src),
        check=True,
        capture_output=True,
        text=True,
    )

    lockfile = src / "uv.lock"
    cmd = ["uv", "sync"]
    if lockfile.exists():
        cmd.append("--frozen")

    subprocess.run(
        cmd,
        cwd=str(src),
        check=True,
        capture_output=True,
        text=True,
        env={
            **__import__("os").environ,
            "VIRTUAL_ENV": str(d / ".venv"),
        },
    )

    logger.info("Venv provisioned for job %s", job_id)


def clean_workspace(job_id: str, keep_logs: bool = True) -> None:
    d = job_dir(job_id)
    if not d.exists():
        return

    for sub in ["src", ".venv", "data", INCOMING_DIR, SPEC_FILE]:
        p = d / sub
        if p.exists():
            if p.is_dir():
                shutil.rmtree(p)
            else:
                p.unlink()
            logger.info("Removed %s", p)

    if not keep_logs:
        logs = d / "logs"
        if logs.exists():
            shutil.rmtree(logs)

    remaining = list(d.iterdir())
    if not remaining:
        d.rmdir()
        logger.info("Removed empty job dir %s", d)


def purge_all() -> None:
    if WORKSPACE_ROOT.exists():
        shutil.rmtree(WORKSPACE_ROOT)
        logger.info("Purged all workspaces at %s", WORKSPACE_ROOT)
