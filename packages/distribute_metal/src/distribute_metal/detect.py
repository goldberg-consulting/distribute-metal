from __future__ import annotations

import os


def detect_environment() -> tuple[int, int, int, bool]:
    """Detect whether we are running under torchrun and return rank info.

    Returns (rank, world_size, local_rank, is_distributed).

    When torchrun sets RANK, WORLD_SIZE, and LOCAL_RANK, those values are
    used and is_distributed is True. Otherwise falls back to single-node
    mode so the same script works for local development without torchrun.
    """
    rank_str = os.environ.get("RANK")
    world_str = os.environ.get("WORLD_SIZE")
    local_str = os.environ.get("LOCAL_RANK")

    if rank_str is not None and world_str is not None:
        return (
            int(rank_str),
            int(world_str),
            int(local_str) if local_str is not None else 0,
            True,
        )

    return (0, 1, 0, False)
