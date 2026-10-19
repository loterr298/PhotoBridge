#!/usr/bin/env python3
"""Physical USB upload interruption/resume acceptance. New App inbox only; never invokes Photos."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import threading
import time
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from album_restore import validated_backup
from upload_resume import upload
from usb_probe import AFC, inspect
from device_usb_cable_resume import usb_phone_present


def source_snapshot(source):
    _, _, resources, _, _ = validated_backup(source)
    result = {}
    for r in resources:
        path = source / r['storedRelativePath']; st = path.stat(); receipt = inspect(path)
        result[r['storedRelativePath']] = [receipt['sha256'], receipt['byteCount'], st.st_mtime_ns, st.st_birthtime]
    return result


def interrupt(source, output):
    source = Path(source).resolve(); output = Path(output)
    if output.resolve() == source or source in output.resolve().parents: raise ValueError('Evidence must be outside source')
    baseline = source_snapshot(source)
    if not usb_phone_present(): raise ValueError('NOT_RUN: no iPhone in IOUSB')
    output.mkdir(mode=0o700, exist_ok=False)
    (output / 'source-state.json').write_text(json.dumps(baseline))
    (output / 'source.json').write_text(json.dumps({'source': str(source)}))
    journals = source / 'restore-uploads'; old = set(journals.glob('*.json'))
    client = AFC(); stop = threading.Event(); events = [{'seconds': 0, 'present': True}]
    started = time.monotonic(); observer_errors = []; failure = None; usb_failure = None; thread = None
    def observe():
        while not stop.wait(.25):
            try:
                present = usb_phone_present()
                if present != events[-1]['present']: events.append({'seconds': time.monotonic() - started, 'present': present})
            except (OSError, subprocess.SubprocessError) as error: observer_errors.append(type(error).__name__)
    try:
        client.vend('com.photobridge.OrderProbe')
        thread = threading.Thread(target=observe, daemon=True); thread.start()
        class SlowWriter:
            def __getattr__(self, name): return getattr(client, name)
            def write_new(self, path, source_reader):
                nonlocal usb_failure
                if '/Resources/' not in path: return client.write_new(path, source_reader)
                local_failed = False
                class Reader:
                    def read(self, size):
                        nonlocal local_failed
                        try:
                            data = source_reader.read(size)
                            # Leave time for a human cable action, not a throughput benchmark.
                            time.sleep(len(data) / 1048576)
                            return data
                        except BaseException:
                            local_failed = True
                            raise
                try: client.write_new(path, Reader())
                except RuntimeError as error:
                    if not local_failed and str(error).startswith(('AFC write: error ', 'AFC open write: error ')):
                        usb_failure = dict(seconds=time.monotonic() - started, error=str(error))
                    raise
        print('USB_UPLOAD_STARTED: waiting for manual cable removal; Photos NOT_RUN', flush=True)
        try: upload(SlowWriter(), source)
        except Exception as error: failure = type(error).__name__ + ': ' + str(error)
        stop.wait(.75)
    finally:
        stop.set()
        if thread: thread.join(timeout=4)
        client.close()
    correlated = usb_failure is not None and any(not e['present'] and
        -1 <= usb_failure['seconds'] - e['seconds'] <= 15 for e in events)
    created = set(journals.glob('*.json')) - old
    if len(created) == 1:
        journal = created.pop()
        (output / 'interrupted-journal.json').write_bytes(journal.read_bytes())
        (output / 'journal-location.json').write_text(json.dumps({'journal': str(journal)}))
    result = dict(status='CABLE_FAILURE_OBSERVED_PENDING_PARTIAL_INSPECTION' if correlated and failure
        else 'PHYSICAL_INTERRUPTION_NOT_PROVEN', failure=failure, USBWriteFailure=usb_failure,
        IOUSBEvents=events, observerErrors=observer_errors, photosImport='NOT_RUN', throughputBenchmark=False)
    (output / 'interruption.json').write_text(json.dumps(result, indent=2))
    return result


def resume(output):
    output = Path(output)
    if output.is_symlink() or not output.is_dir(): raise ValueError('Expected existing test directory')
    interruption = json.loads((output / 'interruption.json').read_bytes())
    if interruption['status'] != 'CABLE_FAILURE_OBSERVED_PENDING_PARTIAL_INSPECTION': raise ValueError('No correlated cable/write failure')
    if not usb_phone_present(): raise ValueError('iPhone not present in IOUSB')
    source = Path(json.loads((output / 'source.json').read_bytes())['source'])
    baseline = json.loads((output / 'source-state.json').read_bytes())
    if source_snapshot(source) != baseline: raise ValueError('Original source changed')
    previous = Path(json.loads((output / 'journal-location.json').read_bytes())['journal'])
    old_journal = previous.read_bytes()
    if old_journal != (output / 'interrupted-journal.json').read_bytes(): raise ValueError('Old journal changed')
    remote = json.loads(old_journal)['remote']; raw, _, resources, digest, total = validated_backup(source)
    client = AFC()
    try:
        client.vend('com.photobridge.OrderProbe')
        if 'restore-request.json' in client.list(remote): raise ValueError('Premature published request')
        complete = {}; partial_bytes = 0; strict_partials = {}
        for r in resources:
            path = remote + '/' + r['storedRelativePath']; parent, name = path.rsplit('/', 1)
            try: names = client.list(parent)
            except RuntimeError as error:
                if str(error) == 'AFC list: error 8': continue
                raise
            if name in names: complete[path] = client.info(path)
            if name + '.part' in names:
                size = int(client.info(path + '.part')['st_size']); partial_bytes += size
                if 0 < size < r['byteCount']: strict_partials[path + '.part'] = (size, r['byteCount'] - size)
        if not strict_partials: raise ValueError('No strict partial resource needing positive suffix; physical continuation not proven')
        publications = []; appended_suffixes = {}
        class Observed:
            def __getattr__(self, name): return getattr(client, name)
            def append_existing(self, path, reader, offset):
                consumed = 0
                class Counted:
                    def read(self, size):
                        nonlocal consumed
                        data = reader.read(size); consumed += len(data); return data
                client.append_existing(path, Counted(), offset)
                if path in strict_partials:
                    expected_offset, expected_suffix = strict_partials[path]
                    if offset != expected_offset or consumed != expected_suffix or consumed <= 0:
                        raise ValueError('Strict partial suffix was not actually appended')
                    appended_suffixes[path] = consumed
            def commit_new(self, part, final):
                client.commit_new(part, final); publications.append(final)
        result = upload(Observed(), source, previous)
        if set(appended_suffixes) != set(strict_partials): raise ValueError('Missing positive partial suffix append')
        for path, before in complete.items():
            after = client.info(path)
            if any(before.get(k) != after.get(k) for k in ['st_size', 'st_mtime', 'st_birthtime', 'st_nlink']):
                raise ValueError('Previously complete phone resource changed')
        for r in resources:
            target = output / 'independent-readback' / r['storedRelativePath']; target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('xb') as stream: client.read(remote + '/' + r['storedRelativePath'], stream.write, r['byteCount'])
            sha = subprocess.check_output(['/usr/bin/shasum', '-a', '256', str(target)], text=True).split()[0]
            if sha != r['sha256'] or target.stat().st_size != r['byteCount']: raise ValueError('Independent hash/size mismatch')
        data = bytearray(); client.read(remote + '/album-order.json', data.extend, len(raw))
        if bytes(data) != raw: raise ValueError('Manifest changed')
        data = bytearray(); client.read(remote + '/restore-request.json', data.extend, 65536)
        if json.loads(data)['sourceManifestSHA256'] != digest: raise ValueError('Wrong ready digest')
        if not publications or publications[-1] != remote + '/restore-request.json': raise ValueError('Ready was not last')
    finally: client.close()
    if source_snapshot(source) != baseline or previous.read_bytes() != old_journal: raise ValueError('Source/old journal changed')
    if result['resumedPartialBytes'] != partial_bytes or result['reusedVerifiedResources'] != len(complete): raise ValueError('Wrong resume accounting')
    if result['usbResourceBytesWritten'] + partial_bytes + sum(int(i['st_size']) for i in complete.values()) != total:
        raise ValueError('Wrong suffix byte accounting')
    summary = {k: result[k] for k in ['resourcesVerified', 'bytesVerified', 'reusedVerifiedResources',
        'resumedPartialBytes', 'usbResourceBytesWritten', 'usbVerificationBytesRead']}
    summary.update(status='PHYSICAL_USB_UPLOAD_RESUME_SAMPLE_PASS', physicalIOUSBRemovalObserved=True,
        newUSBOnlyAFCConnection=True, independentMacShasumMatches=len(resources), sourceBytesMtimeBirthtimeUnchanged=True,
        oldLocalJournalUnchanged=True, previouslyCompletedPhoneFilesUnchanged=True, restoreRequestPublishedLast=True,
        strictPartialResourcesAppended=len(appended_suffixes), strictPartialSuffixBytesWritten=sum(appended_suffixes.values()),
        photosImport='NOT_RUN', throughputBenchmark=False)
    with (output / 'physical-upload-summary.json').open('x') as stream: json.dump(summary, stream, indent=2)
    return summary


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__); p.add_argument('action', choices=['interrupt', 'resume'])
    p.add_argument('--local', type=Path); p.add_argument('--output', type=Path, required=True); a = p.parse_args()
    if a.action == 'interrupt' and a.local is None: p.error('interrupt requires --local committed backup')
    print(json.dumps(interrupt(a.local, a.output) if a.action == 'interrupt' else resume(a.output), indent=2))
