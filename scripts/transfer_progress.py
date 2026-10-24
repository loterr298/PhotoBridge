"""Small, truthful progress records shared by the USB transfer scripts."""
from __future__ import annotations

from typing import Optional


def snapshot(*, status: str, started_monotonic: float, now_monotonic: float,
             resources_verified: int, total_resources: int,
             bytes_verified: int, total_bytes: int,
             current_resource: Optional[str] = None) -> dict:
    elapsed = max(0.0, now_monotonic - started_monotonic)
    speed = bytes_verified / elapsed if elapsed > 0 and bytes_verified > 0 else 0.0
    remaining = max(0, total_bytes - bytes_verified)
    eta = remaining / speed if speed > 0 else None
    fraction = bytes_verified / total_bytes if total_bytes > 0 else 0.0
    return {
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
