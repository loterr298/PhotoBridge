#!/usr/bin/env python3
"""Read-only audit of user-selected Photos preflight reports; no Photos writes."""
import argparse, hashlib, json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from usb_probe import AFC


def _fail(message):
    raise ValueError(message)


def bind_report(report, mode, session, expected_build, manifest_sha, assets, resources, remaining_bytes):
    if report.get('kind') != 'PhotoBridgePreflightReport' or report.get('schemaVersion') != '1.0.0': _fail('invalid report kind')
    if report.get('sessionID') != session or report.get('runtimeBuild') != expected_build: _fail('report binding changed')
    if report.get('photoKitCreationRequestsIssuedByPreflight') is not False: _fail('preflight wrote Photos')
    if report.get('photoAccessAtStart') != report.get('photoAccessAtEnd'): _fail('permission changed during preflight')
    if mode == 'denied':
        required = {'status': 'BLOCKED', 'failureCode': 'FULL_PHOTO_ACCESS_REQUIRED', 'photoAccessAtStart': 'denied', 'photoAccessAtEnd': 'denied', 'resourcesHashVerified': 0}
        if any(report.get(k) != v for k, v in required.items()): _fail('denied report mismatch')
        if any(k in report for k in ('manifestSHA256','assets','resources','actualAvailableBytes','effectiveAvailableBytes','requiredEstimatedBytes')):
            _fail('denied report performed work after permission refusal')
        return
    if report.get('photoAccessAtStart') != 'full' or report.get('manifestSHA256') != manifest_sha:
        _fail('full-access report binding mismatch')
    if report.get('assets') != assets or report.get('resources') != resources:
        _fail('resource count mismatch')
    if mode == 'zero':
        if report.get('resourcesHashVerified') != 0: _fail('zero-space report hashed resources before blocking')
    elif report.get('resourcesHashVerified') != resources:
        _fail('resource hash count mismatch')
    if report.get('remainingPhotoCopyBytes') != remaining_bytes[0] or report.get('remainingReadbackBytes') != remaining_bytes[1]: _fail('budget mismatch')
    required = report.get('requiredEstimatedBytes')
    if not isinstance(required, int) or required != sum(remaining_bytes) + report.get('reserveBytes', -1): _fail('required budget mismatch')
    actual = report.get('actualAvailableBytes'); effective = report.get('effectiveAvailableBytes')
    simulated = report.get('simulatedZeroCapacity')
    if mode == 'zero':
        if report.get('status') != 'BLOCKED' or report.get('failureCode') != 'INSUFFICIENT_ESTIMATED_CAPACITY' or simulated is not True or effective != 0: _fail('zero-space report mismatch')
        return
    if mode == 'ready':
        if report.get('status') != 'READY' or report.get('failureCode') is not None or simulated is not False or not isinstance(actual, int) or effective != actual or actual < required: _fail('ready report mismatch')
        return
    _fail('unknown audit mode')


def unchanged_inbox(before, after, expected):
    if set(before) != expected or set(after) != expected: _fail('inbox baseline incomplete or changed')
    for name in expected:
        old, new = before[name], after[name]
        if not isinstance(old, dict) or not isinstance(new, dict): _fail('invalid inbox receipt')
        if old.get('sha256') != new.get('sha256') or old.get('byteCount') != new.get('byteCount') or old.get('attributes') != new.get('attributes'):
            _fail('inbox bytes or attributes changed')


def read_report(client, remote, relative):
    data = bytearray(); client.read(remote + '/' + relative, data.extend, 4 * 1024 * 1024)
    return json.loads(data)


def audit(client, remote, output, mode, session, expected_build, manifest_sha, assets, resources, remaining_bytes):
    report = read_report(client, remote, 'RestoreChecks/' + session + '.json')
    bind_report(report, mode, session, expected_build, manifest_sha, assets, resources, remaining_bytes)
    output = Path(output); output.mkdir(mode=0o700, exist_ok=False)
    (output / 'preflight-report.json').write_text(json.dumps(report, indent=2) + '\n')
    result = dict(status='PREFLIGHT_REPORT_AUDIT_PASS', mode=mode, sessionID=session, runtimeBuild=expected_build,
                  photoKitCreationRequestsIssuedByPreflight=False, photosWrite='NOT_RUN')
    (output / 'audit.json').write_text(json.dumps(result, indent=2) + '\n')
    return result

if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('--remote', required=True); p.add_argument('--output', type=Path, required=True)
    p.add_argument('--mode', choices=['denied','zero','ready'], required=True); p.add_argument('--session', required=True); p.add_argument('--expected-build', required=True)
    p.add_argument('--manifest-sha', required=True); p.add_argument('--assets', type=int, required=True); p.add_argument('--resources', type=int, required=True)
    p.add_argument('--remaining-photo-copy', type=int, required=True); p.add_argument('--remaining-readback', type=int, required=True); a=p.parse_args()
    c=AFC()
    try:
        c.vend('com.photobridge.OrderProbe'); print(json.dumps(audit(c, a.remote, a.output, a.mode, a.session, a.expected_build, a.manifest_sha, a.assets, a.resources, (a.remaining_photo_copy, a.remaining_readback)), indent=2))
    finally: c.close()
