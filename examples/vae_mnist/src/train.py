"""Distributed VAE training on MNIST using distribute-metal.

Trains a convolutional variational autoencoder across multiple Macs.
Each Mac processes a shard of the dataset; gradients are synchronized
via MCCL all-reduce over Metal Performance Shaders.

Distributed (2+ Macs via distribute-metal app):
    Select the project folder in the menu bar app and click Run.

Local smoke test (single Mac, no torchrun needed):
    python train.py --config=../configs/vae.yaml
"""

import argparse
import time
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F
from torchvision import datasets, transforms

import distribute_metal as dm
import yaml


class Encoder(nn.Module):
    def __init__(self, input_channels: int, hidden_dims: list[int], latent_dim: int):
        super().__init__()
        modules = []
        in_ch = input_channels
        for h_dim in hidden_dims:
            modules.append(nn.Sequential(
                nn.Conv2d(in_ch, h_dim, kernel_size=3, stride=2, padding=1),
                nn.BatchNorm2d(h_dim),
                nn.LeakyReLU(),
            ))
            in_ch = h_dim

        self.encoder = nn.Sequential(*modules)
        self.fc_mu = nn.Linear(hidden_dims[-1] * 7 * 7, latent_dim)
        self.fc_logvar = nn.Linear(hidden_dims[-1] * 7 * 7, latent_dim)

    def forward(self, x: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        h = self.encoder(x)
        h = torch.flatten(h, start_dim=1)
        return self.fc_mu(h), self.fc_logvar(h)


class Decoder(nn.Module):
    def __init__(self, latent_dim: int, hidden_dims: list[int], output_channels: int):
        super().__init__()
        reversed_dims = list(reversed(hidden_dims))
        self.fc = nn.Linear(latent_dim, reversed_dims[0] * 7 * 7)
        self.hidden_dim_0 = reversed_dims[0]

        modules = []
        for i in range(len(reversed_dims) - 1):
            modules.append(nn.Sequential(
                nn.ConvTranspose2d(reversed_dims[i], reversed_dims[i + 1],
                                   kernel_size=3, stride=2, padding=1, output_padding=1),
                nn.BatchNorm2d(reversed_dims[i + 1]),
                nn.LeakyReLU(),
            ))

        modules.append(nn.Sequential(
            nn.ConvTranspose2d(reversed_dims[-1], output_channels,
                               kernel_size=3, stride=2, padding=1, output_padding=1),
            nn.Sigmoid(),
        ))
        self.decoder = nn.Sequential(*modules)

    def forward(self, z: torch.Tensor) -> torch.Tensor:
        h = self.fc(z)
        h = h.view(-1, self.hidden_dim_0, 7, 7)
        return self.decoder(h)


class VAE(nn.Module):
    def __init__(self, input_channels: int, hidden_dims: list[int], latent_dim: int):
        super().__init__()
        self.encoder = Encoder(input_channels, hidden_dims, latent_dim)
        self.decoder = Decoder(latent_dim, hidden_dims, input_channels)

    def reparameterize(self, mu: torch.Tensor, logvar: torch.Tensor) -> torch.Tensor:
        std = torch.exp(0.5 * logvar)
        eps = torch.randn_like(std)
        return mu + eps * std

    def forward(self, x: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        mu, logvar = self.encoder(x)
        z = self.reparameterize(mu, logvar)
        recon = self.decoder(z)
        return recon, mu, logvar


def vae_loss(recon: torch.Tensor, x: torch.Tensor,
             mu: torch.Tensor, logvar: torch.Tensor,
             kl_weight: float = 1.0) -> tuple[torch.Tensor, float, float]:
    recon_loss = F.binary_cross_entropy(recon, x, reduction="sum") / x.size(0)
    kl_loss = -0.5 * torch.sum(1 + logvar - mu.pow(2) - logvar.exp()) / x.size(0)
    total = recon_loss + kl_weight * kl_loss
    return total, recon_loss.item(), kl_loss.item()


def train(config: dict):
    ctx = dm.setup()

    mc = config["model"]
    tc = config["training"]
    dc = config["data"]

    transform = transforms.Compose([transforms.ToTensor()])
    dataset = datasets.MNIST(
        root=dc["root"],
        train=True,
        download=dc.get("download", False),
        transform=transform,
    )

    loader = ctx.wrap_loader(dataset, batch_size=tc["batch_size"])

    model = VAE(
        input_channels=mc["input_channels"],
        hidden_dims=mc["hidden_dims"],
        latent_dim=mc["latent_dim"],
    )
    model = ctx.wrap_model(model)

    optimizer = torch.optim.Adam(model.parameters(), lr=tc["learning_rate"])

    checkpoint_dir = Path("checkpoints")
    if ctx.is_primary:
        checkpoint_dir.mkdir(exist_ok=True)
        total_params = sum(p.numel() for p in ctx.unwrap(model).parameters())
        mode = f"distributed ({ctx.world_size} nodes)" if ctx.is_distributed else "local"
        print(f"VAE: {total_params:,} parameters, latent_dim={mc['latent_dim']}")
        print(f"Training: {mode}, {len(dataset)} samples, device={ctx.device}")
        print(f"Batch size per device: {tc['batch_size']}, "
              f"effective batch size: {tc['batch_size'] * ctx.world_size}")
        print()

    for epoch in range(tc["epochs"]):
        ctx.set_epoch(epoch)
        model.train()

        epoch_loss = 0.0
        epoch_recon = 0.0
        epoch_kl = 0.0
        steps = 0
        t0 = time.perf_counter()

        for batch_idx, (x, _) in enumerate(loader):
            x = x.to(ctx.device)
            optimizer.zero_grad(set_to_none=True)

            recon, mu, logvar = model(x)
            loss, recon_l, kl_l = vae_loss(recon, x, mu, logvar,
                                           kl_weight=tc["kl_weight"])
            loss.backward()
            optimizer.step()

            epoch_loss += loss.item()
            epoch_recon += recon_l
            epoch_kl += kl_l
            steps += 1

            if ctx.is_primary and (batch_idx + 1) % tc["log_interval"] == 0:
                print(f"  [{epoch+1}] step {batch_idx+1}/{len(loader)}  "
                      f"loss={loss.item():.2f}  recon={recon_l:.2f}  kl={kl_l:.2f}")

        elapsed = time.perf_counter() - t0
        avg_loss = epoch_loss / max(steps, 1)
        avg_recon = epoch_recon / max(steps, 1)
        avg_kl = epoch_kl / max(steps, 1)
        throughput = len(dataset) / elapsed

        if ctx.is_primary:
            print(f"epoch {epoch+1}/{tc['epochs']}  "
                  f"loss={avg_loss:.2f}  recon={avg_recon:.2f}  kl={avg_kl:.2f}  "
                  f"{throughput:.0f} img/s  ({elapsed:.1f}s)")

        if ctx.is_primary and (epoch + 1) % 5 == 0:
            path = checkpoint_dir / f"vae_epoch_{epoch+1}.pt"
            torch.save({
                "epoch": epoch + 1,
                "model_state_dict": ctx.unwrap(model).state_dict(),
                "optimizer_state_dict": optimizer.state_dict(),
                "loss": avg_loss,
            }, path)
            print(f"  checkpoint saved: {path}")

    ctx.cleanup()
    if ctx.is_primary:
        print("\nTraining complete.")


def main():
    parser = argparse.ArgumentParser(description="Distributed VAE on MNIST")
    parser.add_argument("--config", type=str, default="../configs/vae.yaml")
    args = parser.parse_args()

    with open(args.config) as f:
        config = yaml.safe_load(f)

    train(config)


if __name__ == "__main__":
    main()
