#!/usr/bin/env python3
"""Continue USB downloads into a new directory, preserving the prior incomplete backup without writes."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import sys
from album_export import download_album, session_path, validate_manifest, write_json
from album_restore import regular_path
from usb_probe import AFC, CHUNK, inspect
from transfer_control import CancellationRequested


def resume_download(client, remote, previous, destination, cancel_file=None):
    remote = session_path(remote); previous = Path(previous); destination = Path(destination)
    resolved_previous = previous.resolve(strict=True); resolved_destination = destination.resolve()
    if resolved_destination == resolved_previous or resolved_previous in resolved_destination.parents:
        raise ValueError('Resume destination must be outside the preserved previous directory')
    journal = regular_path(previous, 'transfer-progress.json')
    if journal.stat().st_size > 64 * 1024 * 1024: raise ValueError('Resume journal exceeds bound')
    progress = json.loads(journal.read_bytes())
    expected_digest = progress.get('sourceManifestSHA256')
    if progress.get('restoration') != 'NOT_RUN' or not isinstance(expected_digest, str) or len(expected_digest) != 64:
        raise ValueError('Not a PhotoBridge download journal')
    stats = {'reusedVerifiedResources': 0, 'resumedPartialBytes': 0, 'usbResourceBytesRead': 0,
             'previousFilesWritten': False, 'photosImport': 'NOT_RUN'}

    class ResumingClient:
        resources = {}
        def read(self, path, sink, maximum=None):
            if path == remote + '/album-order.json':
                raw = io.BytesIO(); client.read(path, raw.write, maximum)
                data = raw.getvalue()
                if hashlib.sha256(data).hexdigest() != expected_digest:
                    raise ValueError('Phone manifest differs from previous download; continuation refused')
                manifest = json.loads(data); validate_manifest(manifest)
                self.resources = {remote + '/' + r['storedRelativePath']: r for a in manifest['assets'] for r in a['resources']}
                sink(data); return
            if path not in self.resources: raise ValueError('Resume path is not in the bound source manifest')
            resource = self.resources[path]; relative = resource['storedRelativePath']
            complete = previous / relative; part = complete.with_name(complete.name + '.part')
            offset = 0
            if complete.exists() or complete.is_symlink():
                complete = regular_path(previous, relative); receipt = inspect(complete)
                if receipt['byteCount'] != resource['byteCount'] or receipt['sha256'] != resource['sha256']:
                    raise ValueError('Previously completed resource is corrupt; not reused or overwritten')
                with complete.open('rb') as source:
                    while True:
                        data = source.read(CHUNK)
                        if not data: break
                        sink(data)
                stats['reusedVerifiedResources'] += 1
                return
            if part.exists() or part.is_symlink():
                part = regular_path(previous, relative + '.part'); info = part.stat(); offset = info.st_size
                if info.st_nlink != 1 or offset > resource['byteCount']:
                    raise ValueError('Invalid or multiply-linked partial resource')
                copied = 0
                with part.open('rb') as source:
                    while True:
                        data = source.read(CHUNK)
                        if not data: break
                        sink(data); copied += len(data)
                if copied != offset: raise ValueError('Partial resource changed while reading')
                stats['resumedPartialBytes'] += offset
            def receive(data):
                stats['usbResourceBytesRead'] += len(data); sink(data)
            if offset:
                client.read(path, receive, maximum, offset=offset)
            else:
                client.read(path, receive, maximum)

    # Existing downloader retains exclusive output, full hashes, both FS times and final manifest checks.
    result = download_album(ResumingClient(), remote, destination, cancel_file)
    write_json(destination / 'resume-report.json', dict(status='VERIFIED', **stats), exclusive=True)
    return dict(result, **stats)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--remote', required=True); parser.add_argument('--from-directory', type=Path, required=True)
    parser.add_argument('--local', type=Path, required=True); parser.add_argument('--bundle', default='com.photobridge.OrderProbe')
    parser.add_argument('--cancel-file', type=Path)
    args = parser.parse_args(); client = None
    try:
        client = AFC(); client.vend(args.bundle)
        result = resume_download(client, args.remote, args.from_directory, args.local, args.cancel_file)
        keys = ['status', 'resourcesVerified', 'bytesVerified', 'reusedVerifiedResources', 'resumedPartialBytes', 'usbResourceBytesRead', 'previousFilesWritten']
        print(json.dumps({k: result[k] for k in keys}, indent=2)); return 0
    except CancellationRequested as error:
        print(json.dumps({'status': 'STOPPED', 'error': str(error)})); return 3
    except Exception as error:
        print(json.dumps({'status': 'FAILED', 'error': str(error)})); return 2
    finally:
        if client: client.close()


if __name__ == '__main__': sys.exit(main())
