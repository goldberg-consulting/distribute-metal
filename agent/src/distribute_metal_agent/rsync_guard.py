"""Restrict inbound rsync to push-only writes under a single receive root."""

from __future__ import annotations

import argparse
import os
import shlex
import sys
from pathlib import Path


def resolve_rsync_command(original_command: str, root: Path) -> list[str]:
    """Validate and rewrite an rsync server command under ``root``.

    Only ``rsync --server`` push commands are accepted. Pull mode is rejected,
    and the final target path must stay inside ``root`` after normalization.
    """
    args = shlex.split(original_command)
    if len(args) < 3 or args[0] != "rsync" or "--server" not in args:
        raise ValueError("Only rsync --server commands are allowed")
    if "--sender" in args:
        raise ValueError("Rsync pull is not allowed")

    resolved_root = root.expanduser().resolve()
    target = Path(args[-1])
    if target.is_absolute():
        resolved_target = target.expanduser().resolve(strict=False)
    else:
        resolved_target = (resolved_root / target).resolve(strict=False)

    try:
        resolved_target.relative_to(resolved_root)
    except ValueError as exc:
        raise ValueError("Rsync target escapes receive root") from exc

    sanitized_args = list(args)
    sanitized_args[-1] = str(resolved_target)
    return sanitized_args


def main() -> None:
    parser = argparse.ArgumentParser(description="Restrict rsync server commands to a single receive root")
    parser.add_argument("--root", required=True, help="Writable root for incoming rsync transfers")
    args = parser.parse_args()

    original_command = os.environ.get("SSH_ORIGINAL_COMMAND", "")
    if not original_command:
        print("Missing SSH_ORIGINAL_COMMAND", file=sys.stderr)
        sys.exit(1)

    try:
        command = resolve_rsync_command(original_command, Path(args.root))
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)

    os.execvp(command[0], command)


if __name__ == "__main__":
    main()
