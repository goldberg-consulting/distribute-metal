from pathlib import Path

import pytest

from distribute_metal_agent.runner import _resolve_within


@pytest.mark.unit
def test_resolve_within_allows_relative_path(tmp_path: Path) -> None:
    resolved = _resolve_within(tmp_path, "src/train.py")
    assert resolved == (tmp_path / "src/train.py").resolve(strict=False)


@pytest.mark.unit
def test_resolve_within_rejects_escape(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="escapes workspace root"):
        _resolve_within(tmp_path, "../outside.py")


@pytest.mark.unit
def test_resolve_within_rejects_absolute_path(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="relative"):
        _resolve_within(tmp_path, "/tmp/outside.py")
