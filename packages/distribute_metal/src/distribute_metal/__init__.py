"""distribute_metal: transparent distributed training on Apple Silicon.

    import distribute_metal as dm

    ctx = dm.setup()
    model = ctx.wrap_model(MyModel())
    loader = ctx.wrap_loader(dataset, batch_size=64)

    for epoch in range(epochs):
        ctx.set_epoch(epoch)
        for batch in loader:
            ...

    ctx.cleanup()
"""

from __future__ import annotations

import torch

from .context import Context
from .detect import detect_environment

__version__ = "0.1.0"

__all__ = ["setup", "Context", "device", "is_distributed", "__version__"]


def setup() -> Context:
    """One-call distributed setup for Apple Silicon Macs.

    Detects whether the script is running under torchrun (distributed)
    or standalone (single-node). Returns a Context that handles DDP
    model wrapping, distributed data loading, and rank-aware utilities.
    """
    rank, world_size, local_rank, distributed = detect_environment()
    return Context(rank, world_size, local_rank, distributed)


device: torch.device = (
    torch.device("mps") if torch.backends.mps.is_available() else torch.device("cpu")
)

is_distributed: bool = detect_environment()[3]
