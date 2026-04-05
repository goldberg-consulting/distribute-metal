"""measured.one.distribute-metal MCP server.

Exposes tools for cluster inspection, YAML generation, and validation
that Cursor's AI agent can call via the Model Context Protocol.

Run via:
    uv run distribute-metal-mcp          (stdio, for Cursor)
    uv run distribute-metal-mcp --sse    (SSE, for debugging)
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP

from .cluster_client import (
    PeerAddress,
    fetch_all_peer_statuses,
    fetch_peer_status,
    load_peers,
    preflight_check,
)
from .yaml_generator import generate_yaml as _generate_yaml
from .yaml_generator import validate_yaml as _validate_yaml

SCHEMA_PATH = Path(__file__).resolve().parents[4] / "schemas" / "distribute-metal.v1.yaml"

mcp = FastMCP(
    "distribute-metal",
    instructions=(
        "measured.one.distribute-metal cluster management. Use these tools to "
        "inspect the Metal DDP training cluster, generate distribute-metal.yaml "
        "job specs, and validate existing specs. Peers run agents on port 8477."
    ),
)


# ---------------------------------------------------------------------------
# Resources
# ---------------------------------------------------------------------------

@mcp.resource("schema://distribute-metal/v1")
def schema_resource() -> str:
    """The full distribute-metal.yaml schema reference (v1)."""
    if SCHEMA_PATH.exists():
        return SCHEMA_PATH.read_text()
    return "Schema file not found. Expected at schemas/distribute-metal.v1.yaml"


@mcp.resource("cluster://peers")
def peers_resource() -> str:
    """Current peer configuration from ~/.config/distribute-metal/peers.yaml."""
    peers = load_peers()
    if not peers:
        return json.dumps({
            "peers": [],
            "hint": "No peers configured. Create ~/.config/distribute-metal/peers.yaml with a 'peers' list.",
        }, indent=2)
    return json.dumps({
        "peers": [{"ip": p.ip, "port": p.port, "name": p.name} for p in peers],
    }, indent=2)


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

@mcp.tool()
async def cluster_status() -> str:
    """Query all known peers and return their status.

    Reads the peer list from ~/.config/distribute-metal/peers.yaml,
    hits GET /status on each agent, and returns a structured summary
    including state, hardware, Python/uv/mccl versions, and free disk.
    """
    peers = load_peers()
    if not peers:
        return json.dumps({
            "error": "No peers configured.",
            "hint": "Create ~/.config/distribute-metal/peers.yaml:\n\npeers:\n  - ip: 192.168.1.100\n  - ip: 192.168.1.101",
        }, indent=2)

    statuses = await fetch_all_peer_statuses(peers)
    result = {
        "peer_count": len(statuses),
        "reachable": sum(1 for s in statuses if s.reachable),
        "unreachable": sum(1 for s in statuses if not s.reachable),
        "peers": [s.summary() for s in statuses],
    }
    return json.dumps(result, indent=2)


@mcp.tool()
async def peer_preflight(peer_ip: str, peer_port: int = 8477) -> str:
    """Deep readiness check on a single peer.

    Queries the agent at peer_ip:peer_port and returns a list of issues
    that would prevent it from participating in a training job:
    wrong arch, missing uv, no mccl, insufficient disk, busy state, etc.
    """
    peer = PeerAddress(ip=peer_ip, port=peer_port)
    status = await fetch_peer_status(peer)
    issues = preflight_check(status)

    result: dict[str, Any] = {
        "peer": status.summary(),
        "ready": len(issues) == 0,
        "issues": issues,
    }
    return json.dumps(result, indent=2)


@mcp.tool()
async def generate_yaml(project_path: str) -> str:
    """Inspect a training project directory and generate a distribute-metal.yaml.

    Looks for pyproject.toml, detects the training entry script, finds data
    directories, reads Python version constraints, and checks for mccl in
    dependencies. Returns the generated YAML content ready to be saved.

    Args:
        project_path: Absolute path to the training project root directory.
    """
    try:
        content = _generate_yaml(project_path)
        return f"# Generated distribute-metal.yaml for {project_path}\n\n{content}"
    except Exception as exc:
        return json.dumps({"error": str(exc)}, indent=2)


@mcp.tool()
async def validate_yaml(yaml_path: str) -> str:
    """Validate an existing distribute-metal.yaml file.

    Parses the YAML, checks required fields, verifies file paths exist,
    and validates the training backend. Returns a list of issues found,
    or confirms the spec is valid.

    Args:
        yaml_path: Absolute path to the distribute-metal.yaml file.
    """
    issues = _validate_yaml(yaml_path)
    if not issues:
        return json.dumps({"valid": True, "message": "Spec is valid."}, indent=2)
    return json.dumps({"valid": False, "issues": issues}, indent=2)


@mcp.tool()
async def preflight_job(yaml_path: str) -> str:
    """Cross-reference a distribute-metal.yaml against the live cluster.

    This is the primary tool for checking whether a job can run. It:
    1. Validates the YAML spec for structural errors
    2. Queries every configured peer for hardware and software state
    3. Runs preflight checks per peer against the spec requirements
    4. Reports what the project needs vs what each peer has

    Returns a structured report: spec issues, per-peer readiness,
    missing tools, insufficient resources, and a go/no-go verdict.

    Args:
        yaml_path: Absolute path to the distribute-metal.yaml file.
    """
    import yaml as _yaml

    report: dict[str, Any] = {"yaml_path": yaml_path}

    spec_issues = _validate_yaml(yaml_path)
    report["spec_issues"] = spec_issues

    spec: dict[str, Any] = {}
    path = Path(yaml_path).resolve()
    if path.exists():
        try:
            with open(path) as f:
                spec = _yaml.safe_load(f) or {}
        except Exception:
            pass

    peers = load_peers()
    if not peers:
        report["cluster"] = {
            "error": "No peers configured in ~/.config/distribute-metal/peers.yaml"
        }
        report["ready"] = False
        return json.dumps(report, indent=2)

    statuses = await fetch_all_peer_statuses(peers)

    peer_reports = []
    all_ready = True
    for status in statuses:
        issues = preflight_check(status, spec)
        ready = len(issues) == 0 and status.reachable
        if not ready:
            all_ready = False
        peer_reports.append({
            "peer": status.summary(),
            "ready": ready,
            "issues": issues,
        })

    report["cluster"] = {
        "total_peers": len(statuses),
        "reachable": sum(1 for s in statuses if s.reachable),
        "ready": sum(1 for p in peer_reports if p["ready"]),
        "peers": peer_reports,
    }

    training = spec.get("training", {})
    torchrun = training.get("torchrun", {})
    nproc = torchrun.get("nproc_per_node", 1)
    ready_count = report["cluster"]["ready"]
    report["world_size"] = ready_count * nproc
    report["ready"] = all_ready and len(spec_issues) == 0 and ready_count > 0

    if not report["ready"]:
        blockers = []
        if spec_issues:
            blockers.append(f"YAML has {len(spec_issues)} issue(s)")
        not_ready = [p for p in peer_reports if not p["ready"]]
        if not_ready:
            blockers.append(f"{len(not_ready)} peer(s) not ready")
        if ready_count == 0:
            blockers.append("No peers available")
        report["blockers"] = blockers

    return json.dumps(report, indent=2)


def main():
    mcp.run()


if __name__ == "__main__":
    main()
