# DistributeMetal implementation notes

- Treat Bonjour discovery and agent health as separate states. A peer can be visible on the LAN and still be unreachable or agent-failed.
- Default sync mode is coordinator-driven `rsync` over SSH. Do not reintroduce peer-side pull as the primary path.
- Workers must not receive credentials that allow direct read access back into the coordinator's live project directory.
- SSH access is per-worker and push-only. Use restricted forced-command rsync on workers.
- The worker job flow is `init -> rsync push -> prepare/provision -> launch`, not `prepare` first.
- Launch must honor the job spec entrypoint, working directory, script args, and training environment.
- MCP is optional. It remains useful for YAML generation and inspection, but sync and benchmarking must work without it.
- Peer benchmark results should reflect the real worker-to-worker path, not only coordinator HTTP latency.
