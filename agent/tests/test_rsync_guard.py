from pathlib import Path

import pytest

from distribute_metal_agent.rsync_guard import resolve_rsync_command


@pytest.mark.unit
def test_resolve_rsync_command_allows_push_within_receive_root(tmp_path: Path) -> None:
    command = "rsync --server -logDtpre.iLsfxCIvu . job-123/incoming/src/"

    resolved = resolve_rsync_command(command, tmp_path)

    assert resolved[0] == "rsync"
    assert resolved[-1] == str((tmp_path / "job-123/incoming/src").resolve(strict=False))


@pytest.mark.unit
def test_resolve_rsync_command_rejects_sender_mode(tmp_path: Path) -> None:
    command = "rsync --server --sender -logDtpre.iLsfxCIvu . job-123/incoming/src/"

    with pytest.raises(ValueError, match="pull"):
        resolve_rsync_command(command, tmp_path)


@pytest.mark.unit
def test_resolve_rsync_command_rejects_escape(tmp_path: Path) -> None:
    command = "rsync --server -logDtpre.iLsfxCIvu . ../secret"

    with pytest.raises(ValueError, match="escapes receive root"):
        resolve_rsync_command(command, tmp_path)
