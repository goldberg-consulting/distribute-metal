"""Minimal MCCL DDP training script for Apple Silicon Macs.

Launch with torchrun:
    # Single machine, 1 GPU (smoke test)
    torchrun --nproc_per_node=1 --nnodes=1 \
        --master_addr=127.0.0.1 --master_port=29500 train.py

    # Two Macs (run on each with matching nnodes/node_rank)
    torchrun --nproc_per_node=1 --nnodes=2 --node_rank=0 \
        --master_addr=<rank0_ip> --master_port=29500 train.py

    torchrun --nproc_per_node=1 --nnodes=2 --node_rank=1 \
        --master_addr=<rank0_ip> --master_port=29500 train.py
"""

import argparse
import os
import time
from pathlib import Path

import torch
import torch.distributed as dist
import torch.nn as nn
from torch.nn.parallel import DistributedDataParallel as DDP
from torch.utils.data import DataLoader, DistributedSampler, TensorDataset

import mccl  # noqa: F401 — registers the "mccl" backend
import yaml


class SimpleNet(nn.Module):
    def __init__(self, input_dim: int, hidden_dim: int, num_layers: int, num_classes: int):
        super().__init__()
        layers = [nn.Linear(input_dim, hidden_dim), nn.ReLU()]
        for _ in range(num_layers - 1):
            layers += [nn.Linear(hidden_dim, hidden_dim), nn.ReLU()]
        layers.append(nn.Linear(hidden_dim, num_classes))
        self.net = nn.Sequential(*layers)

    def forward(self, x):
        return self.net(x)


def load_config(path: str) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def make_synthetic_data(input_dim: int, num_samples: int, num_classes: int, device: torch.device):
    torch.manual_seed(42)
    x = torch.randn(num_samples, input_dim, device=device)
    y = torch.randint(0, num_classes, (num_samples,), device=device)
    return TensorDataset(x, y)


def train(config: dict):
    rank = int(os.environ["RANK"])
    world_size = int(os.environ["WORLD_SIZE"])
    local_rank = int(os.environ.get("LOCAL_RANK", "0"))
    device = torch.device("mps:0")

    dist.init_process_group(backend="mccl", device_id=device)

    mc = config["model"]
    tc = config["training"]
    dc = config["data"]

    dataset = make_synthetic_data(dc["input_dim"], dc["num_samples"], mc["num_classes"], device)
    sampler = DistributedSampler(dataset, num_replicas=world_size, rank=rank, shuffle=True)
    loader = DataLoader(dataset, batch_size=tc["batch_size"], sampler=sampler)

    model = SimpleNet(dc["input_dim"], mc["hidden_dim"], mc["num_layers"], mc["num_classes"]).to(device)
    ddp_model = DDP(model)

    optimizer = torch.optim.AdamW(ddp_model.parameters(), lr=tc["learning_rate"], weight_decay=tc["weight_decay"])
    loss_fn = nn.CrossEntropyLoss()

    for epoch in range(tc["epochs"]):
        sampler.set_epoch(epoch)
        ddp_model.train()
        epoch_loss = 0.0
        step_count = 0
        t0 = time.perf_counter()

        for batch_idx, (x, y) in enumerate(loader):
            optimizer.zero_grad(set_to_none=True)
            loss = loss_fn(ddp_model(x), y)
            loss.backward()
            optimizer.step()

            epoch_loss += loss.item()
            step_count += 1

            if rank == 0 and (batch_idx + 1) % tc["log_interval"] == 0:
                print(f"  step {batch_idx + 1}: loss={loss.item():.4f}")

        elapsed = time.perf_counter() - t0
        avg_loss = epoch_loss / max(step_count, 1)
        samples_per_sec = len(dataset) / elapsed

        if rank == 0:
            print(
                f"epoch {epoch + 1}/{tc['epochs']}  "
                f"loss={avg_loss:.4f}  "
                f"{samples_per_sec:.1f} samples/s  "
                f"({elapsed:.2f}s)"
            )

    dist.destroy_process_group()
    if rank == 0:
        print("Training complete.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=str, default="../configs/train.yaml")
    args = parser.parse_args()
    config = load_config(args.config)
    train(config)


if __name__ == "__main__":
    main()
