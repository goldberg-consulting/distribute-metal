from __future__ import annotations

from typing import Any

import torch
import torch.nn as nn
from torch.utils.data import DataLoader, Dataset, DistributedSampler


class Context:
    """Manages distributed training state for Apple Silicon Macs.

    Wraps torch.distributed init, DDP model wrapping, and distributed
    data loading behind a small API so training scripts do not need to
    import or configure any of that directly.

    If is_distributed is False (single-node, no torchrun), all methods
    degrade gracefully: wrap_model returns the model unchanged,
    wrap_loader returns a standard shuffled DataLoader, and cleanup
    is a no-op.
    """

    def __init__(
        self,
        rank: int,
        world_size: int,
        local_rank: int,
        is_distributed: bool,
    ) -> None:
        self.rank = rank
        self.world_size = world_size
        self.local_rank = local_rank
        self.is_distributed = is_distributed
        self.is_primary = rank == 0
        self.device = _resolve_device()
        self._samplers: list[DistributedSampler] = []

        if is_distributed:
            _init_process_group(self.device)

    def wrap_model(self, model: nn.Module) -> nn.Module:
        """Move model to device and wrap with DDP if distributed."""
        model = model.to(self.device)
        if not self.is_distributed:
            return model

        from torch.nn.parallel import DistributedDataParallel as DDP

        return DDP(model)

    def wrap_loader(
        self,
        dataset: Dataset,
        batch_size: int = 32,
        num_workers: int = 0,
        pin_memory: bool = False,
        **kwargs: Any,
    ) -> DataLoader:
        """Create a DataLoader with distributed sampling if needed."""
        if self.is_distributed:
            sampler = DistributedSampler(
                dataset,
                num_replicas=self.world_size,
                rank=self.rank,
            )
            self._samplers.append(sampler)
            return DataLoader(
                dataset,
                batch_size=batch_size,
                sampler=sampler,
                num_workers=num_workers,
                pin_memory=pin_memory,
                **kwargs,
            )

        return DataLoader(
            dataset,
            batch_size=batch_size,
            shuffle=True,
            num_workers=num_workers,
            pin_memory=pin_memory,
            **kwargs,
        )

    def set_epoch(self, epoch: int) -> None:
        """Notify all distributed samplers of the current epoch."""
        for sampler in self._samplers:
            sampler.set_epoch(epoch)

    @staticmethod
    def unwrap(model: nn.Module) -> nn.Module:
        """Return the underlying module, stripping DDP if present."""
        if hasattr(model, "module"):
            return model.module
        return model

    def barrier(self) -> None:
        """Synchronize all ranks. No-op when not distributed."""
        if self.is_distributed:
            import torch.distributed as dist

            dist.barrier()

    def cleanup(self) -> None:
        """Tear down the process group if distributed."""
        if self.is_distributed:
            import torch.distributed as dist

            dist.destroy_process_group()

    def print(self, *args: Any, **kwargs: Any) -> None:
        """Print only on rank 0 to avoid duplicate output."""
        if self.is_primary:
            __builtins__["print"](*args, **kwargs)  # type: ignore[index]


def _resolve_device() -> torch.device:
    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def _init_process_group(device: torch.device) -> None:
    import torch.distributed as dist

    try:
        import mccl  # noqa: F401 -- side-effect: registers the backend
    except ImportError as exc:
        raise ImportError(
            "mccl is required for distributed training on Apple Silicon. "
            "Install it with: pip install mccl"
        ) from exc

    dist.init_process_group(backend="mccl", device_id=device)
