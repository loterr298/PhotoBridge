#!/usr/bin/env python3
"""Return a verified backup to a fresh iPhone App inbox using USB-only AFC. Photos import requires the App."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import stat
import sys
import time
import uuid
from album_export import validate_manifest, write_json
from usb_probe import AFC, inspect
from transfer_progress import snapshot
from transfer_control import CancellationRequested, check_cancel
from backup_layout import local_path, upload_journals, upload_journal_name


def regular_path(root, relative):
    current = root
    relative = str(local_path(root, relative).relative_to(root))
    parts = Path(relative).parts
    if Path(relative).is_absolute() or any(p in ('', '.', '..') for p in parts):
        raise ValueError('Unsafe backup path')
    if not stat.S_ISDIR(root.lstat().st_mode): raise ValueError('Backup root must be a real directory')
    for index, component in enumerate(parts):
        current = current / component
        mode = current.lstat().st_mode
        if not (stat.S_ISREG(mode) if index == len(parts) - 1 else stat.S_ISDIR(mode)):
            raise ValueError('Backup symlink/nonregular path rejected')
    return current


def validated_backup(local, cancel_file=None):
    local = Path(local)
    manifest_path = regular_path(local, 'album-order.json')
    if manifest_path.stat().st_size > 64 * 1024 * 1024: raise ValueError('Manifest exceeds bound')
    raw = manifest_path.read_bytes(); manifest = json.loads(raw); validate_manifest(manifest)
    committed = json.loads(regular_path(local, 'transfer-manifest.json').read_bytes())
    resources = [r for a in manifest['assets'] for r in a['resources']]
    digest = hashlib.sha256(raw).hexdigest(); total = sum(r['byteCount'] for r in resources)
    if (committed.get('status') != 'COMMITTED' or committed.get('sourceManifestSHA256') != digest
            or committed.get('resourcesVerified') != len(resources) or committed.get('bytesVerified') != total):
        raise ValueError('Backup is not a matching committed transfer')
    # Validate every local resource before writing any phone data.
    for resource in resources:
        check_cancel(cancel_file)
        receipt = inspect(regular_path(local, resource['storedRelativePath']))
        if receipt['sha256'] != resource['sha256'] or receipt['byteCount'] != resource['byteCount']:
            raise ValueError('Local backup byte/hash mismatch')
    return raw, manifest, resources, digest, total


def upload_backup(client, local, cancel_file=None):
    local = Path(local)
    check_cancel(cancel_file)
    raw, manifest, resources, digest, total = validated_backup(local, cancel_file=cancel_file)
    manifest_path = regular_path(local, 'album-order.json')
    session = str(uuid.uuid4()).upper(); remote = 'RestoreInbox/' + session
    journals = upload_journals(local)
    if journals.is_symlink(): raise ValueError('Upload journal must not be a symbolic link')
    journals.mkdir(mode=0o700, exist_ok=True)
    journal = journals / upload_journal_name(local,session)
    start = time.monotonic()
    progress = snapshot(status='UPLOADING', started_monotonic=start, now_monotonic=start,
                        resources_verified=0, total_resources=len(resources),
                        bytes_verified=0, total_bytes=total)
    progress.update({'state': 'UPLOADING', 'remote': remote, 'photosImport': 'NOT_RUN',
                     'sourceManifestSHA256': digest})
    write_json(journal, progress)

    def copy_and_verify(relative, source, expected_size, expected_hash):
        destination = remote + '/' + relative; part = destination + '.part'
        client.write_new(part, source)
        actual = hashlib.sha256(); count = 0
        def receive(data):
            nonlocal count
            count += len(data); actual.update(data)
        client.read(part, receive, expected_size)
        if count != expected_size or actual.hexdigest() != expected_hash:
            raise ValueError('USB upload readback size/SHA-256 mismatch')
        client.commit_new(part, destination)

    try:
        client.mkdir('RestoreInbox'); client.mkdir(remote, exclusive=True)
        client.mkdir(remote + '/Resources')
        for asset in manifest['assets']:
            client.mkdir(remote + '/Resources/' + f'{asset["ordinal"]:06d}', exclusive=True)
            for resource in asset['resources']:
                check_cancel(cancel_file)
                progress.update(snapshot(status='UPLOADING', started_monotonic=start, now_monotonic=time.monotonic(),
                                         resources_verified=progress['resourcesVerified'],
                                         total_resources=len(resources), bytes_verified=progress['bytesVerified'],
                                         total_bytes=total, current_resource=resource['storedRelativePath']))
                progress['state'] = 'UPLOADING'; progress['photosImport'] = 'NOT_RUN'; progress['remote'] = remote
                progress['sourceManifestSHA256'] = digest
                write_json(journal, progress)
                with regular_path(local, resource['storedRelativePath']).open('rb') as source:
                    copy_and_verify(resource['storedRelativePath'], source, resource['byteCount'], resource['sha256'])
                progress.update(snapshot(status='UPLOADING', started_monotonic=start, now_monotonic=time.monotonic(),
                                         resources_verified=progress['resourcesVerified'] + 1,
                                         total_resources=len(resources), bytes_verified=progress['bytesVerified'] + resource['byteCount'],
                                         total_bytes=total, current_resource=resource['storedRelativePath']))
                progress['state'] = 'UPLOADING'; progress['photosImport'] = 'NOT_RUN'; progress['remote'] = remote
                progress['sourceManifestSHA256'] = digest
                write_json(journal, progress)
        if manifest_path.read_bytes() != raw: raise ValueError('Source manifest changed during upload')
        copy_and_verify('album-order.json', io.BytesIO(raw), len(raw), digest)
        request = {'schemaVersion': '1.0.0', 'kind': 'PhotoBridgeRestoreRequest', 'sessionID': session,
            'state': 'USB_VERIFIED', 'sourceManifestSHA256': digest, 'assetCount': len(manifest['assets']),
            'resourceCount': len(resources), 'byteCount': total, 'photosImport': 'NOT_RUN'}
        request_raw = json.dumps(request, indent=2).encode()
        copy_and_verify('restore-request.json', io.BytesIO(request_raw), len(request_raw), hashlib.sha256(request_raw).hexdigest())
        progress.update(state='USB_VERIFIED', seconds=time.monotonic() - start)
        progress['MiBPerSecondIncludingVerification'] = total / 1048576 / progress['seconds']
        write_json(journal, progress)
        return progress
    except CancellationRequested as error:
        progress.update(state='STOPPED', error=str(error)); write_json(journal, progress)
        raise
    except Exception as error:
        progress.update(state='FAILED', error=str(error)); write_json(journal, progress)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--local', type=Path, required=True)
    parser.add_argument('--bundle', default='com.photobridge.OrderProbe')
    parser.add_argument('--cancel-file', type=Path)
    args = parser.parse_args(); client = None
    try:
        client = AFC(); client.vend(args.bundle); result = upload_backup(client, args.local, args.cancel_file)
        print(json.dumps(result, indent=2)); return 0
    except CancellationRequested as error:
        print(json.dumps({'state': 'STOPPED', 'error': str(error)})); return 3
    except Exception as error:
        print(json.dumps({'state': 'FAILED', 'error': str(error)})); return 2
    finally:
        if client: client.close()


if __name__ == '__main__': sys.exit(main())
