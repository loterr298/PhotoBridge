"""Small, truthful progress records shared by the USB transfer scripts."""
from __future__ import annotations

from typing import Optional
import math


def snapshot(*, status: str, started_monotonic: float, now_monotonic: float,
             resources_verified: int, total_resources: int,
             bytes_verified: int, total_bytes: int,
             current_resource: Optional[str] = None,
             assets_verified: Optional[int] = None, total_assets: Optional[int] = None) -> dict:
    elapsed = now_monotonic - started_monotonic
    elapsed = max(0.0, elapsed) if math.isfinite(elapsed) else 0.0
    speed = bytes_verified / elapsed if elapsed > 0 and bytes_verified > 0 else 0.0
    remaining = max(0, total_bytes - bytes_verified)
    eta = remaining / speed if speed > 0 else None
    fraction = bytes_verified / total_bytes if total_bytes > 0 else 0.0
    value = {
        'status': status,
        'resourcesVerified': resources_verified,
        'totalResources': total_resources,
        'bytesVerified': bytes_verified,
        'totalBytes': total_bytes,
        'fraction': min(1.0, max(0.0, fraction)),
        'bytesPerSecond': speed,
        'etaSeconds': eta,
        'currentResource': current_resource,
    }

    if assets_verified is not None and total_assets is not None:
        if type(assets_verified) is not int or type(total_assets) is not int or not 0 <= assets_verified <= total_assets:
            raise ValueError('Invalid logical photo counts')
        finished = status in ('USB_VERIFIED', 'COMMITTED') and assets_verified == total_assets
        value.update(assetsVerified=assets_verified, totalAssets=total_assets,
                     percent=(100 if finished else min(99, assets_verified * 100 // total_assets)) if total_assets else None)
    return value


class ProgressRelay:
    """At most four small USB UI writes/second; never a media acceptance signal."""
    def __init__(self, client, operation_id, direction):
        self.client, self.operation_id, self.direction = client, operation_id, direction
        self.last_time, self.last_phase = float('-inf'), None
        self.error = None
        self.prepared = False

    def __call__(self, state):
        import json, time
        phase = state.get('status') or state.get('state') or 'PREPARING'
        now = time.monotonic()
        bucket = 'TRANSFERRING' if phase in ('WAITING_FOR_PHOTO', 'DOWNLOADING') else phase
        if bucket == self.last_phase and now - self.last_time < .25:
            return
        self.last_time, self.last_phase = now, bucket
        total = state.get('totalAssets', 0)
        done = state.get('assetsVerified', 0)
        if total == 0:
            done, total = state.get('scannedAssets', 0), state.get('scanTotalAssets', 0)
        value = dict(kind='PhotoBridgeTransferDisplay', operationID=self.operation_id,
                     direction=self.direction, phase=phase, completed=done, total=total,
                     sessionID=state.get('remote', '').split('/')[-1], updatedAt=time.time())
        try:
            if not self.prepared:
                self.client.mkdir('Control')
                self.prepared = True
            raw = json.dumps(value, allow_nan=False, separators=(',', ':')).encode()
            self.client.replace_progress('Control/transfer-progress.json', raw)
            self.error = None
        except Exception as error:
            # A display failure must never change verification/commit decisions.
            self.error = str(error)
