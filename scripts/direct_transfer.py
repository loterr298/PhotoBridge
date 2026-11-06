"""Single-session ordered media transfer primitives for the V4 import path."""

from __future__ import annotations

import hashlib
import io
import json
import os
import re
from pathlib import Path
from typing import Callable


SUPPORTED_EXTENSIONS = {
    "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "dng", "gif",
    "mov", "mp4", "m4v",
}


def ordered_media_files(folder: Path, ordered_names: list[str] | None = None) -> list[Path]:
    """Return regular, supported media in the same order shown by the Mac UI."""
    if folder.is_symlink() or not folder.is_dir():
        raise ValueError("source folder must be a regular directory")
    files = []
    for path in folder.iterdir():
        if path.name.startswith(".") or path.is_symlink() or not path.is_file():
            continue
        if path.suffix.lower().lstrip(".") in SUPPORTED_EXTENSIONS:
            files.append(path)
    if ordered_names is not None:
        by_name = {path.name: path for path in files}
        if len(set(ordered_names)) != len(ordered_names) or set(ordered_names) != set(by_name):
            raise ValueError("order file does not match source folder")
        return [by_name[name] for name in ordered_names]

    def natural_key(path: Path):
        return tuple(
            (0, int(part)) if part.isdigit() else (1, part.casefold())
            for part in re.split(r"(\d+)", path.name)
            if part
        )

    return sorted(files, key=natural_key)


def _safe_name(path: Path) -> str:
    name = path.name
    if not name or name in {".", ".."} or "/" in name or "\\" in name or "\x00" in name:
        raise ValueError("unsafe filename")
    return name


def _validate_session(session: str) -> None:
    if not re.fullmatch(r"[0-9A-Fa-f-]{36}", session):
        raise ValueError("invalid direct session")


class DirectBatchRunner:
    """Upload a folder with one AFC/House Arrest session.

    The client is created once and kept open for every ordered item. Each item
    still uses a temporary file and an atomic rename before its JSON marker is
    written, so the iPhone watcher never observes a partial resource.
    """

    def __init__(
        self,
        source: Path,
        session: str,
        client_factory: Callable[[], object],
        bundle: str,
        progress: Callable[[dict], None] | None = None,
        cancel: Callable[[], None] | None = None,
        ordered_names: list[str] | None = None,
    ):
        self.source = Path(source)
        self.session = session
        self.client_factory = client_factory
        self.bundle = bundle
        self.progress = progress
        self.cancel = cancel
        self.ordered_names = ordered_names

    def _report(self, value: dict) -> None:
        if self.progress:
            self.progress(value)

    def _check_cancel(self) -> None:
        if self.cancel:
            self.cancel()

    def run(self) -> dict:
        _validate_session(self.session)
        files = ordered_media_files(self.source, self.ordered_names)
        client = self.client_factory()
        root = f"DirectInbox/{self.session}"
        started = __import__("time").monotonic()
        completed = 0
        total_bytes = sum(path.stat().st_size for path in files)
        uploaded_bytes = 0
        try:
            client.vend(self.bundle)
            for directory in ("DirectInbox", root):
                try:
                    client.mkdir(directory)
                except Exception:
                    # AFC reports an existing directory as an error. Reuse is
                    # safe because each session ID is freshly generated.
                    pass
            for ordinal, source in enumerate(files, start=1):
                self._check_cancel()
                name = _safe_name(source)
                item = f"{root}/{ordinal:06d}"
                try:
                    client.mkdir(item)
                except Exception:
                    pass
                part = f"{item}/{name}.part"
                final = f"{item}/{name}"
                digest = hashlib.sha256()
                size = 0
                runner = self

                class HashingReader:
                    def __init__(self, stream):
                        self.stream = stream

                    def read(self, count=-1):
                        nonlocal size, uploaded_bytes
                        data = self.stream.read(count)
                        if data:
                            digest.update(data)
                            size += len(data)
                            uploaded_bytes += len(data)
                            runner._report({
                                "status": "UPLOADING",
                                "completed": completed,
                                "total": len(files),
                                "bytesCompleted": uploaded_bytes,
                                "totalBytes": total_bytes,
                                "currentResource": name,
                                "elapsedSeconds": max(0.0, __import__("time").monotonic() - started),
                            })
                        return data

                with source.open("rb") as stream:
                    client.write_new(part, HashingReader(stream))
                self._check_cancel()
                client.commit_new(part, final)
                marker = json.dumps({
                    "sessionID": self.session,
                    "ordinal": ordinal,
                    "filename": name,
                    "relativePath": final,
                    "byteCount": size,
                    "sha256": digest.hexdigest(),
                }, sort_keys=True).encode()
                client.write_new(f"{item}/item.json", io.BytesIO(marker))
                completed = ordinal
                self._report({
                    "status": "UPLOADING",
                    "completed": completed,
                    "total": len(files),
                    "bytesCompleted": uploaded_bytes,
                    "totalBytes": total_bytes,
                    "currentResource": "",
                    "elapsedSeconds": max(0.0, __import__("time").monotonic() - started),
                })
            result = {
                "status": "COMMITTED",
                "completed": completed,
                "total": len(files),
                "bytesCompleted": uploaded_bytes,
                "totalBytes": total_bytes,
                "elapsedSeconds": max(0.0, __import__("time").monotonic() - started),
            }
            self._report(result)
            return result
        finally:
            client.close()
