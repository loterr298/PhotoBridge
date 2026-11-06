#!/usr/bin/env python3
"""Stream a normal Mac folder to the iPhone direct-import inbox."""

import argparse
import json
import time
from pathlib import Path

from direct_transfer import DirectBatchRunner
from transfer_control import check_cancel
from usb_probe import AFC


def write_progress(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".part")
    temporary.write_text(json.dumps(state, sort_keys=True), encoding="utf-8")
    temporary.replace(path)


parser = argparse.ArgumentParser()
parser.add_argument("--local", type=Path, required=True)
parser.add_argument("--session", required=True)
parser.add_argument("--bundle", default="com.photobridge.OrderProbe")
parser.add_argument("--progress-file", type=Path, required=True)
parser.add_argument("--order-file", type=Path, required=True)
parser.add_argument("--cancel-file", type=Path)
args = parser.parse_args()


def progress(state: dict) -> None:
    payload = {
        "kind": "PhotoBridgeTransferDisplay",
        "operationID": args.session,
        "direction": "TO_IPHONE",
        "phase": state.get("status", "UPLOADING"),
        "completed": state.get("completed", 0),
        "total": state.get("total", 0),
        "sessionID": args.session,
        "updatedAt": time.time(),
        "elapsedSeconds": state.get("elapsedSeconds", 0),
        "bytesCompleted": state.get("bytesCompleted", 0),
        "totalBytes": state.get("totalBytes", 0),
        "currentResource": state.get("currentResource", ""),
    }
    if payload["totalBytes"] > 0 and payload["bytesCompleted"] > 0:
        payload["bytesPerSecond"] = payload["bytesCompleted"] / max(payload["elapsedSeconds"], 0.001)
        payload["etaSeconds"] = max(0, payload["totalBytes"] - payload["bytesCompleted"]) / max(payload["bytesPerSecond"], 0.001)
    write_progress(args.progress_file, payload)


def cancel() -> None:
    check_cancel(args.cancel_file)


try:
    ordered_names = json.loads(args.order_file.read_text(encoding="utf-8"))
    if not isinstance(ordered_names, list) or not all(isinstance(name, str) for name in ordered_names):
        raise ValueError("invalid order file")
    progress({"status": "CONNECTING", "total": 0, "completed": 0, "elapsedSeconds": 0})
    result = DirectBatchRunner(
        source=args.local,
        session=args.session,
        client_factory=AFC,
        bundle=args.bundle,
        progress=progress,
        cancel=cancel,
        ordered_names=ordered_names,
    ).run()
    progress(result)
    print(json.dumps(result, sort_keys=True))
except Exception as error:
    progress({"status": "FAILED", "total": 0, "completed": 0, "error": str(error), "elapsedSeconds": 0})
    raise
