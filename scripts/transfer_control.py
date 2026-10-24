"""Cooperative cancellation for USB transfers; never kills a writer mid-commit."""
from pathlib import Path
from typing import Optional


class CancellationRequested(RuntimeError):
    pass


def check_cancel(marker: Optional[Path]) -> None:
    if marker is not None and marker.exists():
        raise CancellationRequested('用户请求安全停止；已保留现场，可从断点继续')
