#!/usr/bin/env python3
"""Manual real-device test: controlled receiver interruption, not physical cable loss. Writes new local copies only."""
import argparse
import datetime
import io
import json
from pathlib import Path
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from usb_probe import AFC, inspect
from album_export import download_album, session_path, validate_manifest
from album_resume import resume_download


def run(remote, output):
    remote = session_path(remote); output = Path(output); client = None
    try:
        client = AFC(); client.vend('com.photobridge.OrderProbe')
        raw = io.BytesIO(); client.read(remote + '/album-order.json', raw.write, 64 * 1024 * 1024)
        manifest = json.loads(raw.getvalue()); validate_manifest(manifest)
        resources = [r for a in manifest['assets'] for r in a['resources']]
        if len(resources) < 2 or resources[1]['byteCount'] < 2: raise ValueError('Need at least two resources and a splittable second resource')
        chosen = resources[1]; cut = chosen['byteCount'] // 2
        output.mkdir(mode=0o700, exist_ok=False)
        (output / 'source-manifest.json').write_bytes(raw.getvalue())
        previous = output / 'interrupted'; target = output / 'completed'
        class InterruptedClient:
            def read(self, path, sink, maximum=None):
                if path != remote + '/' + chosen['storedRelativePath']: return client.read(path, sink, maximum)
                count = 0
                def receive(data):
                    nonlocal count
                    size = min(len(data), cut - count)
                    if size > 0: sink(data[:size]); count += size
                    if count >= cut: raise OSError('CONTROLLED_RECEIVER_INTERRUPTION; cable remained connected')
                client.read(path, receive, maximum)
        interrupted = False
        try: download_album(InterruptedClient(), remote, previous)
        except OSError as error:
            if 'CONTROLLED_RECEIVER_INTERRUPTION' not in str(error): raise
            interrupted = True
        if not interrupted or (previous / 'transfer-manifest.json').exists(): raise AssertionError('Invalid interruption state')
    finally:
        if client: client.close(); client = None
    def snapshot():
        result = {}
        for path in previous.rglob('*'):
            if path.is_file():
                attributes = path.stat(); receipt = inspect(path)
                result[str(path.relative_to(previous))] = (receipt['sha256'], receipt['byteCount'], attributes.st_mtime_ns, attributes.st_birthtime)
        return result
    before = snapshot()
    if (previous / (chosen['storedRelativePath'] + '.part')).stat().st_size != cut: raise AssertionError('Incorrect partial size')
    try:
        client = AFC(); client.vend('com.photobridge.OrderProbe')
        result = resume_download(client, remote, previous, target)
    finally:
        if client: client.close()
    if before != snapshot(): raise AssertionError('Previous files changed')
    verified = 0; base = datetime.datetime.fromisoformat(manifest['sourceOrder']['capturedAt'].replace('Z', '+00:00')).timestamp()
    for asset in manifest['assets']:
        for resource in asset['resources']:
            path = target / resource['storedRelativePath']; attributes = path.stat()
            digest = subprocess.check_output(['/usr/bin/shasum', '-a', '256', str(path)], text=True).split()[0]
            expected = base + (asset['ordinal'] - 1) * 5
            if digest != resource['sha256'] or attributes.st_size != resource['byteCount']: raise AssertionError('Independent hash/size failed')
            if abs(attributes.st_mtime - expected) >= .001 or abs(attributes.st_birthtime - expected) >= .001: raise AssertionError('Filesystem time failed')
            verified += 1
    if result['resumedPartialBytes'] != cut or result['reusedVerifiedResources'] != 1: raise AssertionError('Wrong resume/reuse counts')
    if result['usbResourceBytesRead'] != sum(r['byteCount'] for r in resources) - resources[0]['byteCount'] - cut:
        raise AssertionError('Wrong USB byte accounting')
    keys = ['status', 'resourcesVerified', 'bytesVerified', 'reusedVerifiedResources', 'resumedPartialBytes', 'usbResourceBytesRead', 'previousFilesWritten']
    summary = {key: result[key] for key in keys}
    summary.update(controlledReceiverInterruption=True, physicalCableDisconnected=False,
        newAFCConnectionForContinuation=True, independentMacShasumMatches=verified,
        oldBytesMtimeBirthtimeUnchanged=True, allNewBirthAndMtimeIntervalsVerified=True,
        scope='Actual USB-only AFC seek after controlled client interruption; not cable-loss or Photos transaction recovery')
    (output / 'device-resume-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--remote', required=True); parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.remote, args.output), indent=2))
