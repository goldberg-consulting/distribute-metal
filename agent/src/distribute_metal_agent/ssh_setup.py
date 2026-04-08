"""SSH authorization helpers for restricted rsync push access.

The worker only accepts coordinator keys that are tied to a forced command,
which delegates to ``rsync_guard`` and confines writes to the DistributeMetal
receive root.
"""

from __future__ import annotations

import getpass
import shlex
import shutil
from pathlib import Path

AUTHORIZED_KEYS = Path.home() / ".ssh" / "authorized_keys"
HOST_KEY_FILES = [
    Path("/etc/ssh/ssh_host_ed25519_key.pub"),
    Path("/etc/ssh/ssh_host_rsa_key.pub"),
]


def authorize_public_key(public_key: str, key_name: str | None, receive_root: Path, python_executable: str) -> None:
    _ = key_name
    sanitized_key = sanitize_public_key(public_key)
    force_command = build_force_command(receive_root, python_executable)
    options = [
        "restrict",
        f'command="{force_command}"',
    ]

    entry = f"{','.join(options)} {sanitized_key}"

    AUTHORIZED_KEYS.parent.mkdir(parents=True, exist_ok=True)
    existing = AUTHORIZED_KEYS.read_text() if AUTHORIZED_KEYS.exists() else ""
    key_body = sanitized_key.split()[1]
    if key_body in existing:
        return

    with AUTHORIZED_KEYS.open("a", encoding="utf8") as handle:
        if existing and not existing.endswith("\n"):
            handle.write("\n")
        handle.write(entry)
        handle.write("\n")


def build_force_command(receive_root: Path, python_executable: str) -> str:
    return " ".join(
        [
            shlex.quote(python_executable),
            "-m",
            "distribute_metal_agent.rsync_guard",
            "--root",
            shlex.quote(str(receive_root)),
        ]
    )


def sanitize_public_key(public_key: str) -> str:
    sanitized = public_key.strip()
    if "\n" in sanitized or "\r" in sanitized:
        raise ValueError("Public key must be a single line")

    parts = sanitized.split()
    if len(parts) < 2 or parts[0] not in {"ssh-ed25519", "ssh-rsa"}:
        raise ValueError("Only ssh-ed25519 and ssh-rsa public keys are supported")
    return sanitized


def current_ssh_user() -> str:
    return getpass.getuser()


def host_public_keys() -> list[str]:
    keys: list[str] = []
    for path in HOST_KEY_FILES:
        if path.exists():
            text = path.read_text(encoding="utf8").strip()
            if text:
                keys.append(text)
    return keys


def rsync_available() -> bool:
    return shutil.which("rsync") is not None
