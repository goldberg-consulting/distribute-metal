"""Inspect a training project directory and generate a distribute-metal.yaml spec."""
from __future__ import annotations

import re
from pathlib import Path
from typing import Any

import yaml


def generate_yaml(project_path: str) -> str:
    """Inspect *project_path* and return a complete distribute-metal.yaml as a string."""
    root = Path(project_path).resolve()
    if not root.is_dir():
        raise FileNotFoundError(f"Project path is not a directory: {root}")

    spec: dict[str, Any] = {"version": 1}

    spec["project"] = _build_project_section(root)
    spec["python"] = _build_python_section(root)
    spec["training"] = _build_training_section(root)
    spec["data"] = _detect_data_sources(root)
    spec["sync"] = {
        "mode": "bulk",
        "parallel_connections": 8,
        "chunk_size_mb": 64,
        "preferred_interface": "auto",
    }
    spec["cleanup"] = {
        "delete_venv_on_success": True,
        "delete_source_on_success": True,
        "delete_data_on_success": False,
        "retain_logs_days": 7,
    }
    spec["validation"] = {
        "require_arm64": True,
        "min_free_disk_gb": 10,
        "required_tools": ["uv", "python3"],
        "check_firewall": True,
    }

    return yaml.dump(spec, default_flow_style=False, sort_keys=False, allow_unicode=True)


def validate_yaml(yaml_path: str) -> list[str]:
    """Parse an existing distribute-metal.yaml and return a list of errors/warnings."""
    path = Path(yaml_path).resolve()
    issues: list[str] = []

    if not path.exists():
        return [f"File not found: {path}"]

    try:
        with open(path) as f:
            data = yaml.safe_load(f)
    except yaml.YAMLError as exc:
        return [f"YAML parse error: {exc}"]

    if not isinstance(data, dict):
        return ["Top-level YAML must be a mapping"]

    if data.get("version") != 1:
        issues.append(f"Unsupported schema version: {data.get('version')} (expected 1)")

    project = data.get("project", {})
    if not project.get("name"):
        issues.append("project.name is required")
    if not project.get("entrypoint"):
        issues.append("project.entrypoint is required")
    else:
        root = path.parent / project.get("root", ".")
        entry = root / project.get("working_dir", ".") / project["entrypoint"]
        if not entry.exists():
            issues.append(f"Entrypoint not found: {entry}")

    python = data.get("python", {})
    if not python.get("version"):
        issues.append("python.version is required")
    pyproject = path.parent / python.get("pyproject", "pyproject.toml")
    if not pyproject.exists():
        issues.append(f"pyproject.toml not found at {pyproject}")

    training = data.get("training", {})
    if training.get("backend") not in ("mccl", "gloo", "nccl"):
        issues.append(f"Unknown training backend: {training.get('backend')}")

    return issues


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _build_project_section(root: Path) -> dict[str, Any]:
    name = root.name
    entrypoint = _find_entrypoint(root)
    working_dir = "."

    if entrypoint and "/" in entrypoint:
        parts = entrypoint.rsplit("/", 1)
        working_dir = parts[0]
        entrypoint = parts[1]

    include_globs = ["**/*.py", "pyproject.toml"]
    if (root / "uv.lock").exists():
        include_globs.append("uv.lock")
    for pattern in ("configs", "config"):
        if (root / pattern).is_dir():
            include_globs.append(f"{pattern}/**")

    exclude_globs = [".git/**", ".venv/**", "__pycache__/**", "checkpoints/**"]

    return {
        "name": name,
        "root": ".",
        "working_dir": working_dir,
        "entrypoint": entrypoint or "train.py",
        "include": include_globs,
        "exclude": exclude_globs,
    }


def _build_python_section(root: Path) -> dict[str, Any]:
    section: dict[str, Any] = {
        "version": ">=3.11,<3.14",
        "pyproject": "pyproject.toml",
        "lockfile": "uv.lock",
    }

    pyproject = root / "pyproject.toml"
    if pyproject.exists():
        text = pyproject.read_text()
        m = re.search(r'requires-python\s*=\s*"([^"]+)"', text)
        if m:
            section["version"] = m.group(1)

    return section


def _build_training_section(root: Path) -> dict[str, Any]:
    section: dict[str, Any] = {
        "backend": "mccl",
        "torchrun": {
            "nproc_per_node": 1,
            "master_port": 29500,
            "script_args": [],
        },
        "env": {},
        "checkpoint_dir": "checkpoints",
        "rank0_only": {
            "save_checkpoints": True,
            "write_logs": True,
        },
    }

    pyproject = root / "pyproject.toml"
    if pyproject.exists():
        text = pyproject.read_text()
        has_mccl = "mccl" in text
        if not has_mccl:
            section["backend"] = "gloo"

    for cfg_dir in ("configs", "config"):
        cfg_path = root / cfg_dir
        if cfg_path.is_dir():
            yamls = list(cfg_path.glob("*.yaml")) + list(cfg_path.glob("*.yml"))
            if yamls:
                rel = yamls[0].relative_to(root)
                section["torchrun"]["script_args"] = [f"--config={rel}"]
                break

    return section


def _find_entrypoint(root: Path) -> str | None:
    """Find the most likely training entry script."""
    candidates = [
        "train.py", "main.py", "run.py",
        "src/train.py", "src/main.py", "src/run.py",
    ]
    for c in candidates:
        if (root / c).exists():
            return c

    for py in root.rglob("*.py"):
        try:
            text = py.read_text(errors="ignore")
        except Exception:
            continue
        if "torchrun" in text or "dist.init_process_group" in text or "import mccl" in text:
            return str(py.relative_to(root))

    return None


def _detect_data_sources(root: Path) -> list[dict[str, Any]]:
    """Look for dataset directories and return data spec entries."""
    sources: list[dict[str, Any]] = []
    for name in ("data", "datasets", "dataset"):
        d = root / name
        if d.is_dir() and any(d.iterdir()):
            sources.append({
                "name": name,
                "source": "coordinator",
                "path": name,
            })
    return sources
