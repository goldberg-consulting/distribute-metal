from __future__ import annotations

import logging
import os
import signal
import subprocess
from pathlib import Path

from .workspace import job_dir

logger = logging.getLogger(__name__)

_active_processes: dict[str, subprocess.Popen] = {}


def launch_torchrun(
    job_id: str,
    entrypoint: str,
    master_addr: str,
    master_port: int,
    world_size: int,
    node_rank: int,
    nproc_per_node: int = 1,
    script_args: list[str] | None = None,
    env_overrides: dict[str, str] | None = None,
    working_dir: str | None = None,
) -> None:
    """Start a torchrun process for the given job."""
    d = job_dir(job_id)
    venv = d / ".venv"
    src = d / "src"

    cwd = src / working_dir if working_dir else src
    log_file = d / "logs" / "torchrun.log"

    torchrun_bin = venv / "bin" / "torchrun"
    if not torchrun_bin.exists():
        torchrun_bin_str = "torchrun"
    else:
        torchrun_bin_str = str(torchrun_bin)

    cmd = [
        torchrun_bin_str,
        f"--nproc_per_node={nproc_per_node}",
        f"--nnodes={world_size // nproc_per_node}",
        f"--node_rank={node_rank}",
        f"--master_addr={master_addr}",
        f"--master_port={master_port}",
        entrypoint,
    ]
    if script_args:
        cmd.extend(script_args)

    env = {
        **os.environ,
        "VIRTUAL_ENV": str(venv),
        "PATH": f"{venv / 'bin'}:{os.environ.get('PATH', '')}",
    }
    if env_overrides:
        env.update(env_overrides)

    logger.info("Launching: %s (cwd=%s)", " ".join(cmd), cwd)

    log_file.parent.mkdir(parents=True, exist_ok=True)
    log_fh = open(log_file, "w")

    proc = subprocess.Popen(
        cmd,
        cwd=str(cwd),
        env=env,
        stdout=log_fh,
        stderr=subprocess.STDOUT,
    )

    _active_processes[job_id] = proc
    logger.info("torchrun started for job %s (pid=%d)", job_id, proc.pid)


def is_running(job_id: str) -> bool:
    proc = _active_processes.get(job_id)
    if proc is None:
        return False
    return proc.poll() is None


def poll_exit_code(job_id: str) -> int | None:
    proc = _active_processes.get(job_id)
    if proc is None:
        return None
    return proc.poll()


def stop_job(job_id: str) -> None:
    proc = _active_processes.pop(job_id, None)
    if proc is None:
        return

    if proc.poll() is None:
        logger.info("Sending SIGTERM to job %s (pid=%d)", job_id, proc.pid)
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            logger.warning("SIGKILL for job %s (pid=%d)", job_id, proc.pid)
            proc.kill()
            proc.wait()

    logger.info("Stopped job %s", job_id)


def read_logs(job_id: str, tail: int = 200) -> list[str]:
    log_file = job_dir(job_id) / "logs" / "torchrun.log"
    if not log_file.exists():
        return []
    lines = log_file.read_text().splitlines()
    return lines[-tail:]
