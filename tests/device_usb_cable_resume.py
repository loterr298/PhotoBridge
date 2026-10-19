#!/usr/bin/env python3
"""Two-step physical cable-loss acceptance harness. New local copies only; no Photos or phone writes."""
import argparse
import datetime
import json
from pathlib import Path
import re
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from album_export import download_album, session_path, validate_manifest
from album_resume import resume_download
from usb_probe import AFC, inspect


def usb_phone_present():
    raw = subprocess.check_output(['/usr/sbin/ioreg', '-p', 'IOUSB', '-l', '-w', '0'], text=True, timeout=3)
    return bool(re.search(r'"USB Product Name"\s*=\s*"iPhone"', raw))


def snapshot(root):
    result = {}
    for path in root.rglob('*'):
        if path.is_symlink(): raise ValueError('Unexpected symlink in preserved test directory')
        if path.is_file():
            receipt = inspect(path); attributes = path.stat()
            result[str(path.relative_to(root))] = dict(sha256=receipt['sha256'], byteCount=receipt['byteCount'],
                mtimeNS=attributes.st_mtime_ns, birthtime=attributes.st_birthtime)
    return result


def interrupt(remote, output):
    remote = session_path(remote); output = Path(output)
    if not usb_phone_present(): raise ValueError('NOT_RUN: no iPhone in IOUSB before starting')
    output.mkdir(mode=0o700, exist_ok=False)
    (output / 'request.json').write_text(json.dumps({'remote': remote}))
    client = AFC(); stop = threading.Event(); events = [{'seconds': 0, 'present': True}]
    started = time.monotonic(); observer_errors = []; thread = None
    def observe():
        while not stop.wait(.25):
            try:
                present = usb_phone_present()
                if present != events[-1]['present']:
                    events.append({'seconds': time.monotonic() - started, 'present': present})
            except (OSError, subprocess.SubprocessError) as error: observer_errors.append(type(error).__name__)
    failure = None; usb_read_failure = None
    try:
        client.vend('com.photobridge.OrderProbe')
        thread = threading.Thread(target=observe, daemon=True); thread.start()
        class SlowReadOnlyClient:
            def read(self, path, sink, maximum=None):
                nonlocal usb_read_failure
                callback_failed = False
                def receive(data):
                    nonlocal callback_failed
                    try:
                        sink(data)
                        # Keep the real transfer observable long enough for the manual cable action.
                        if '/Resources/' in path: time.sleep(len(data) / 1048576)
                    except BaseException:
                        callback_failed = True
                        raise
                try: client.read(path, receive, maximum)
                except RuntimeError as error:
                    # AFC.check's protocol errors are separate from sink, hash, disk and attribute failures.
                    if (not callback_failed and '/Resources/' in path
                            and str(error).startswith(('AFC read: error ', 'AFC open read: error '))):
                        usb_read_failure = {'seconds': time.monotonic() - started, 'error': str(error)}
                    raise
        print('READ_ONLY_BACKUP_STARTED: waiting for manual physical cable removal', flush=True)
        try: download_album(SlowReadOnlyClient(), remote, output / 'interrupted')
        except Exception as error: failure = type(error).__name__ + ': ' + str(error)
        stop.wait(.75)
    finally:
        stop.set()
        if thread: thread.join(timeout=4)
        client.close()
    absent = any(not event['present'] for event in events)
    old = output / 'interrupted'; partials = list(old.rglob('*.part'))
    correlated = usb_read_failure is not None and any(not event['present'] and
        -1 <= usb_read_failure['seconds'] - event['seconds'] <= 15 for event in events)
    eligible = (failure is not None and absent and correlated and old.is_dir()
                and not (old / 'transfer-manifest.json').exists() and any(p.stat().st_size > 0 for p in partials))
    (output / 'preserved-state.json').write_text(json.dumps(snapshot(old), indent=2) + '\n')
    result = dict(status='INTERRUPTED_AWAITING_RECONNECT' if eligible else 'PHYSICAL_INTERRUPTION_NOT_PROVEN',
        failure=failure, USBReadFailure=usb_read_failure, IOUSBEvents=events, observerErrors=observer_errors,
        nonemptyPartialFiles=sum(p.stat().st_size > 0 for p in partials), phoneFilesWritten=False,
        scope='IOUSB removal plus failed actual USB read required; receiver throttled to 1 MiB/s for manual timing')
    (output / 'interruption.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def resume(output):
    output = Path(output); old = output / 'interrupted'
    if output.is_symlink() or not output.is_dir(): raise ValueError('Expected existing physical-test directory')
    interrupted = json.loads((output / 'interruption.json').read_text())
    if interrupted['status'] != 'INTERRUPTED_AWAITING_RECONNECT': raise ValueError('Physical interruption was not proven')
    if not usb_phone_present(): raise ValueError('iPhone is not back in IOUSB')
    baseline = json.loads((output / 'preserved-state.json').read_text())
    if snapshot(old) != baseline: raise ValueError('Interrupted bytes or timestamps changed before continuation')
    remote = session_path(json.loads((output / 'request.json').read_text())['remote'])
    client = AFC()
    try:
        client.vend('com.photobridge.OrderProbe')
        result = resume_download(client, remote, old, output / 'completed')
    finally: client.close()
    manifest = json.loads((output / 'completed/album-order.json').read_text()); validate_manifest(manifest)
    base = datetime.datetime.fromisoformat(manifest['sourceOrder']['capturedAt'].replace('Z', '+00:00')).timestamp()
    count = 0
    for asset in manifest['assets']:
        for resource in asset['resources']:
            path = output / 'completed' / resource['storedRelativePath']; attributes = path.stat()
            digest = subprocess.check_output(['/usr/bin/shasum', '-a', '256', str(path)], text=True).split()[0]
            expected = base + (asset['ordinal'] - 1) * 5
            if digest != resource['sha256'] or attributes.st_size != resource['byteCount']: raise ValueError('Independent bytes mismatch')
            if abs(attributes.st_mtime - expected) >= .001 or abs(attributes.st_birthtime - expected) >= .001:
                raise ValueError('New copy filesystem time mismatch')
            count += 1
    if snapshot(old) != baseline or result['previousFilesWritten'] or result['resumedPartialBytes'] <= 0:
        raise ValueError('Old state changed or actual partial-byte continuation missing')
    summary = {key: result[key] for key in ['status', 'resourcesVerified', 'bytesVerified',
        'reusedVerifiedResources', 'resumedPartialBytes', 'usbResourceBytesRead', 'previousFilesWritten']}
    summary.update(physicalIOUSBRemovalObserved=True, newUSBOnlyAFCConnection=True,
        independentMacShasumMatches=count, oldBytesMtimeBirthtimeUnchanged=True,
        allNewBirthAndMtimeIntervalsVerified=True, phoneFilesWritten=False,
        scope='Physical cable-loss continuation of Mac download only; not upload, phone staging or Photos transactions')
    with (output / 'physical-resume-summary.json').open('x') as stream: json.dump(summary, stream, indent=2)
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['interrupt', 'resume']); parser.add_argument('--remote')
    parser.add_argument('--output', type=Path, required=True); args = parser.parse_args()
    if args.action == 'interrupt' and not args.remote: parser.error('interrupt requires --remote Exports/<UUID>')
    print(json.dumps(interrupt(args.remote, args.output) if args.action == 'interrupt' else resume(args.output), indent=2))
