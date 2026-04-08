"""distribute-metal CLI.

Usage:
    distribute-metal init              # generate distribute-metal.yaml in current dir
    distribute-metal init /path/to/project
    distribute-metal status            # query local agent
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


def cmd_init(args: argparse.Namespace) -> None:
    project = Path(args.path).resolve()
    if not project.is_dir():
        print(f"Error: {project} is not a directory", file=sys.stderr)
        sys.exit(1)

    pyproject = project / "pyproject.toml"
    if not pyproject.exists():
        print(f"Error: no pyproject.toml in {project}", file=sys.stderr)
        sys.exit(1)

    detected_entrypoint = _detect_entrypoint(project)
    working_dir = str(Path(detected_entrypoint).parent)
    if working_dir == ".":
        working_dir = "."
    entrypoint = Path(detected_entrypoint).name
    name = project.name.lower().replace(" ", "-")
    has_lockfile = (project / "uv.lock").exists()
    data_dirs = _detect_data_dirs(project)
    python_version = _read_python_version(pyproject) or ">=3.11"

    include_lines = '    - "**/*.py"\n    - "pyproject.toml"'
    if has_lockfile:
        include_lines += '\n    - "uv.lock"'

    data_block = "data: []"
    if data_dirs:
        entries = "\n".join(
            f'  - name: "{d}"\n    source: "coordinator"\n    path: "{d}"'
            for d in data_dirs
        )
        data_block = f"data:\n{entries}"

    yaml = f"""version: 1

project:
  name: "{name}"
  root: "."
  working_dir: "{working_dir}"
  entrypoint: "{entrypoint}"
  include:
{include_lines}
  exclude:
    - ".git/**"
    - ".venv/**"
    - "__pycache__/**"
    - "checkpoints/**"

python:
  version: "{python_version}"
  pyproject: "pyproject.toml"
  lockfile: "{'uv.lock' if has_lockfile else ''}"

training:
  backend: "mccl"
  torchrun:
    nproc_per_node: 1
    master_port: 29500

{data_block}

sync:
  mode: "rsync-push"
  parallel_connections: 8
  chunk_size_mb: 64

cleanup:
  delete_venv_on_success: true
  delete_source_on_success: true
  delete_data_on_success: false
  retain_logs_days: 7

validation:
  require_arm64: true
  min_free_disk_gb: 10
  required_tools:
    - "uv"
    - "python3"
"""

    out = project / "distribute-metal.yaml"
    if out.exists() and not args.force:
        print(f"distribute-metal.yaml already exists. Use --force to overwrite.", file=sys.stderr)
        sys.exit(1)

    out.write_text(yaml)
    print(f"Created {out}")
    print(f"  project:    {name}")
    print(f"  entrypoint: {entrypoint}")
    print(f"  working dir: {working_dir}")
    print(f"  python:     {python_version}")
    if data_dirs:
        print(f"  data dirs:  {', '.join(data_dirs)}")
    print(f"\nEdit the file, then open it from the DM menu bar to run.")


def cmd_status(args: argparse.Namespace) -> None:
    import json
    import urllib.request
    import urllib.error

    url = f"http://{args.host}:{args.port}/status"
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read())
        print(f"Agent:   {data.get('agent_version', '?')}")
        print(f"State:   {data.get('state', '?')}")
        print(f"Chip:    {data.get('chip', '?')}")
        print(f"Memory:  {data.get('memory_gb', '?')} GB")
        print(f"macOS:   {data.get('macos_version', '?')}")
        print(f"Python:  {data.get('python_version', '?')}")
        print(f"uv:      {'yes' if data.get('uv_available') else 'no'}")
        print(f"mccl:    {data.get('mccl_version') or 'not found'}")
        print(f"Disk:    {data.get('free_disk_gb', '?')} GB free")
        if data.get("job_id"):
            print(f"Job:     {data['job_id']}")
    except Exception as e:
        print(f"Could not reach agent at {url}: {e}", file=sys.stderr)
        sys.exit(1)


def _detect_entrypoint(project: Path) -> str:
    candidates = ["train.py", "main.py", "run.py", "src/train.py", "src/main.py"]
    for c in candidates:
        if (project / c).exists():
            return c

    src = project / "src"
    if src.is_dir():
        for f in sorted(src.iterdir()):
            if f.suffix == ".py" and not f.name.startswith("__"):
                return f"src/{f.name}"

    for f in sorted(project.iterdir()):
        if f.suffix == ".py" and not f.name.startswith(("__", "setup", "conftest")):
            return f.name

    return "train.py"


def _detect_data_dirs(project: Path) -> list[str]:
    return [d for d in ["data", "datasets", "dataset"] if (project / d).is_dir()]


def _read_python_version(pyproject: Path) -> str | None:
    for line in pyproject.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith("requires-python"):
            parts = stripped.split("=", 1)
            if len(parts) == 2:
                return parts[1].strip().strip('"').strip("'")
    return None


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="distribute-metal",
        description="measured.one.distribute-metal CLI",
    )
    sub = parser.add_subparsers(dest="command")

    init_p = sub.add_parser("init", help="Generate a distribute-metal.yaml for a project")
    init_p.add_argument("path", nargs="?", default=".", help="Project directory (default: current)")
    init_p.add_argument("--force", "-f", action="store_true", help="Overwrite existing file")

    status_p = sub.add_parser("status", help="Query the local agent")
    status_p.add_argument("--host", default="127.0.0.1", help="Agent host")
    status_p.add_argument("--port", type=int, default=8477, help="Agent port")

    args = parser.parse_args()
    if args.command == "init":
        cmd_init(args)
    elif args.command == "status":
        cmd_status(args)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
