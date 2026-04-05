"""Async HTTP client that wraps DistributeMetal agent APIs for MCP tool use."""
from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx
import yaml


PEERS_CONFIG_PATH = Path.home() / ".config" / "distribute-metal" / "peers.yaml"
TOKEN_FILE = Path.home() / ".config" / "distribute-metal" / "token"
DEFAULT_AGENT_PORT = 8477
REQUEST_TIMEOUT = 10.0


def load_token() -> str | None:
    import os
    token = os.environ.get("DISTRIBUTE_METAL_TOKEN")
    if token:
        return token.strip()
    if TOKEN_FILE.exists():
        lines = TOKEN_FILE.read_text().strip().splitlines()
        if lines:
            return lines[0].strip()
    return None


@dataclass
class PeerAddress:
    ip: str
    port: int = DEFAULT_AGENT_PORT
    name: str | None = None

    @property
    def base_url(self) -> str:
        return f"http://{self.ip}:{self.port}"


@dataclass
class PeerStatus:
    peer: PeerAddress
    reachable: bool
    state: str | None = None
    job_id: str | None = None
    arch: str | None = None
    chip: str | None = None
    memory_gb: int | None = None
    macos_version: str | None = None
    agent_version: str | None = None
    mccl_version: str | None = None
    python_version: str | None = None
    uv_available: bool | None = None
    free_disk_gb: float | None = None
    error: str | None = None

    def summary(self) -> dict[str, Any]:
        d: dict[str, Any] = {
            "ip": self.peer.ip,
            "port": self.peer.port,
            "reachable": self.reachable,
        }
        if self.peer.name:
            d["name"] = self.peer.name
        if not self.reachable:
            d["error"] = self.error or "unreachable"
            return d
        for attr in (
            "state", "job_id", "arch", "chip", "memory_gb", "macos_version",
            "agent_version", "mccl_version", "python_version", "uv_available",
            "free_disk_gb",
        ):
            val = getattr(self, attr)
            if val is not None:
                d[attr] = val
        return d


def load_peers() -> list[PeerAddress]:
    """Load peer list from ~/.config/distribute-metal/peers.yaml."""
    if not PEERS_CONFIG_PATH.exists():
        return []
    with open(PEERS_CONFIG_PATH) as f:
        data = yaml.safe_load(f) or {}
    peers: list[PeerAddress] = []
    for entry in data.get("peers", []):
        if isinstance(entry, str):
            peers.append(PeerAddress(ip=entry))
        elif isinstance(entry, dict):
            peers.append(PeerAddress(
                ip=entry["ip"],
                port=entry.get("port", DEFAULT_AGENT_PORT),
                name=entry.get("name"),
            ))
    return peers


async def fetch_peer_status(peer: PeerAddress) -> PeerStatus:
    """Query GET /status on a single agent."""
    try:
        headers = {}
        token = load_token()
        if token:
            headers["Authorization"] = f"Bearer {token}"
        async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT) as client:
            resp = await client.get(f"{peer.base_url}/status", headers=headers)
            resp.raise_for_status()
            data = resp.json()
            return PeerStatus(
                peer=peer,
                reachable=True,
                state=data.get("state"),
                job_id=data.get("job_id"),
                arch=data.get("arch"),
                chip=data.get("chip"),
                memory_gb=data.get("memory_gb"),
                macos_version=data.get("macos_version"),
                agent_version=data.get("agent_version"),
                mccl_version=data.get("mccl_version"),
                python_version=data.get("python_version"),
                uv_available=data.get("uv_available"),
                free_disk_gb=data.get("free_disk_gb"),
            )
    except Exception as exc:
        return PeerStatus(peer=peer, reachable=False, error=str(exc))


async def fetch_all_peer_statuses(peers: list[PeerAddress] | None = None) -> list[PeerStatus]:
    """Query all known peers concurrently."""
    if peers is None:
        peers = load_peers()
    if not peers:
        return []
    return await asyncio.gather(*(fetch_peer_status(p) for p in peers))


def preflight_check(status: PeerStatus, spec: dict[str, Any] | None = None) -> list[str]:
    """Return a list of issues for a peer given an optional job spec."""
    issues: list[str] = []

    if not status.reachable:
        issues.append(f"Peer unreachable: {status.error}")
        return issues

    if status.arch and status.arch != "arm64":
        issues.append(f"Not Apple Silicon: arch={status.arch}")

    if not status.uv_available:
        issues.append("uv is not installed")

    if not status.python_version:
        issues.append("Python version unknown")

    if not status.mccl_version:
        issues.append("mccl not installed (required for Metal DDP)")

    if spec:
        validation = spec.get("validation", {})
        min_disk = validation.get("min_free_disk_gb", 10)
        if status.free_disk_gb is not None and status.free_disk_gb < min_disk:
            issues.append(f"Insufficient disk: {status.free_disk_gb:.1f} GB free, need {min_disk} GB")

    if status.state and status.state not in ("idle", "cleaned"):
        issues.append(f"Peer is busy: state={status.state}")

    return issues
