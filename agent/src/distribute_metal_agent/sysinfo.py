from __future__ import annotations

import os
import platform
import shutil
import subprocess


def get_arch() -> str:
    return platform.machine()


def get_chip() -> str:
    try:
        result = subprocess.run(
            ["sysctl", "-n", "machdep.cpu.brand_string"],
            capture_output=True, text=True, timeout=5,
        )
        return result.stdout.strip() or "Apple Silicon"
    except Exception:
        return "Apple Silicon"


def get_memory_gb() -> int:
    try:
        result = subprocess.run(
            ["sysctl", "-n", "hw.memsize"],
            capture_output=True, text=True, timeout=5,
        )
        return int(result.stdout.strip()) // (1024 ** 3)
    except Exception:
        return 0


def get_macos_version() -> str:
    return platform.mac_ver()[0]


def get_free_disk_gb() -> float:
    usage = shutil.disk_usage(os.path.expanduser("~"))
    return round(usage.free / (1024 ** 3), 1)


def get_uv_available() -> bool:
    return shutil.which("uv") is not None


def get_python_version() -> str:
    return platform.python_version()


def get_mccl_version() -> str | None:
    try:
        result = subprocess.run(
            ["python3", "-c", "import mccl; print(mccl.__version__)"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return None
