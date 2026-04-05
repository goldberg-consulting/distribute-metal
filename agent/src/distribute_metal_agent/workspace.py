from __future__ import annotations

import logging
import shutil
import subprocess
from pathlib import Path

logger = logging.getLogger(__name__)

WORKSPACE_ROOT = Path.home() / "Library" / "Application Support" / "DistributeMetal" / "jobs"


def job_dir(job_id: str) -> Path:
    return WORKSPACE_ROOT / job_id


def ensure_workspace(job_id: str) -> Path:
    d = job_dir(job_id)
    (d / "src").mkdir(parents=True, exist_ok=True)
    (d / "data").mkdir(exist_ok=True)
    (d / "logs").mkdir(exist_ok=True)
    return d


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

    for sub in ["src", ".venv", "data"]:
        p = d / sub
        if p.exists():
            shutil.rmtree(p)
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
