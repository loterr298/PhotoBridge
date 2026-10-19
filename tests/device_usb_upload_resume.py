#!/usr/bin/env python3
"""Controlled source-reader interruption during actual USB upload; not a physical cable-loss test."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from album_restore import validated_backup
from upload_resume import upload
from usb_probe import AFC, inspect


def run(source, output):
    source = Path(source); output = Path(output)
    raw, manifest, resources, digest, total = validated_backup(source)
    chosen = resources[1]; cut = chosen['byteCount'] // 2
    if cut <= 0: raise ValueError('Need a splittable second resource')
    if output.resolve() == source.resolve() or source.resolve() in output.resolve().parents:
        raise ValueError('Test evidence must be outside the preserved source')
    def source_state():
        result = {}
        for resource in resources:
            p = source / resource['storedRelativePath']; info = p.stat(); receipt = inspect(p)
            result[resource['storedRelativePath']] = (receipt['sha256'], receipt['byteCount'], info.st_mtime_ns, info.st_birthtime)
        return result
    before = source_state(); output.mkdir(mode=0o700, exist_ok=False)
    journals = source / 'restore-uploads'; existing = set(journals.glob('*.json')) if journals.exists() else set()
    c = AFC()
    try:
        c.vend('com.photobridge.OrderProbe')
        class InterruptedClient:
            def __getattr__(self, name): return getattr(c, name)
            def write_new(self, path, data):
                if not path.endswith('/' + chosen['storedRelativePath'] + '.part'): return c.write_new(path, data)
                class Prefix:
                    remaining = cut
                    def read(self, size):
                        if self.remaining <= 0: raise OSError('CONTROLLED_LOCAL_SOURCE_INTERRUPTION; USB stayed connected')
                        result = data.read(min(size, self.remaining)); self.remaining -= len(result); return result
                c.write_new(path, Prefix())
        try: upload(InterruptedClient(), source)
        except OSError as error:
            if 'CONTROLLED_LOCAL_SOURCE_INTERRUPTION' not in str(error): raise
        else: raise AssertionError('Expected controlled writer interruption')
    finally: c.close()
    created = set(journals.glob('*.json')) - existing
    if len(created) != 1: raise AssertionError('Expected one failed upload journal')
    previous = created.pop(); old_journal = previous.read_bytes(); remote = json.loads(old_journal)['remote']
    c = AFC()
    try:
        c.vend('com.photobridge.OrderProbe')
        if 'restore-request.json' in c.list(remote): raise AssertionError('Premature ready request')
        if int(c.info(remote + '/' + chosen['storedRelativePath'] + '.part')['st_size']) != cut:
            raise AssertionError('Wrong partial prefix size')
        first_info = c.info(remote + '/' + resources[0]['storedRelativePath'])
        publications = []
        class ObservedClient:
            def __getattr__(self, name): return getattr(c, name)
            def commit_new(self, part, final):
                c.commit_new(part, final); publications.append(final)
        result = upload(ObservedClient(), source, previous)
        expected_publications = [remote + '/' + r['storedRelativePath'] for r in resources[1:]]
        expected_publications += [remote + '/album-order.json', remote + '/restore-request.json']
        if publications != expected_publications: raise AssertionError('Unexpected publication ordering')
        if c.info(remote + '/' + resources[0]['storedRelativePath']) != first_info:
            # Reading may change atime on some devices; only compare preservation-relevant attributes below.
            after_info = c.info(remote + '/' + resources[0]['storedRelativePath'])
            if any(after_info.get(k) != first_info.get(k) for k in ['st_size', 'st_mtime', 'st_birthtime', 'st_nlink']):
                raise AssertionError('Previously complete phone file changed')
        for r in resources:
            target = output / r['storedRelativePath']; target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('xb') as stream: c.read(remote + '/' + r['storedRelativePath'], stream.write, r['byteCount'])
            sha = subprocess.check_output(['/usr/bin/shasum', '-a', '256', str(target)], text=True).split()[0]
            if sha != r['sha256'] or target.stat().st_size != r['byteCount']: raise AssertionError('Independent upload hash/size failed')
        observed = bytearray(); c.read(remote + '/album-order.json', observed.extend, len(raw))
        if bytes(observed) != raw: raise AssertionError('Manifest bytes changed')
        request = bytearray(); c.read(remote + '/restore-request.json', request.extend, 65536)
        if json.loads(request)['sourceManifestSHA256'] != digest: raise AssertionError('Wrong ready digest')
    finally: c.close()
    if source_state() != before or previous.read_bytes() != old_journal: raise AssertionError('Source or old journal changed')
    if result['resumedPartialBytes'] != cut or result['reusedVerifiedResources'] != 1:
        raise AssertionError('Wrong continuation accounting')
    if result['usbResourceBytesWritten'] != total - resources[0]['byteCount'] - cut:
        raise AssertionError('Wrong resource USB write-byte accounting')
    summary = {k: result[k] for k in ['state', 'resourcesVerified', 'bytesVerified', 'reusedVerifiedResources',
        'resumedPartialBytes', 'usbResourceBytesWritten', 'usbVerificationBytesRead']}
    summary.update(controlledLocalSourceInterruption=True, physicalCableDisconnected=False,
        newUSBOnlyAFCConnection=True, independentMacShasumMatches=len(resources),
        sourceBytesMtimeBirthtimeUnchanged=True, oldLocalJournalUnchanged=True,
        previouslyCompletedPhoneFileUnchanged=True, restoreRequestPublishedLast=True,
        observedAtomicPublications=len(publications), photosImport='NOT_RUN')
    (output / 'private-session.json').write_text(json.dumps(dict(remote=remote, journal=result['journal']), indent=2))
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    return summary


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__); p.add_argument('--local', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True); a = p.parse_args()
    print(json.dumps(run(a.local, a.output), indent=2))
