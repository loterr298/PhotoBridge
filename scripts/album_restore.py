#!/usr/bin/env python3
"""Return a verified backup to a fresh iPhone App inbox using USB-only AFC. Photos import requires the App."""
import argparse
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import time
import uuid
from album_export import validate_manifest, write_json
from usb_probe import AFC, inspect
from transfer_progress import snapshot
from transfer_control import CancellationRequested, check_cancel
from backup_layout import local_path, upload_journals, upload_journal_name

GENERIC_IMAGE_EXTENSIONS = {
    'jpg': 'public.jpeg', 'jpeg': 'public.jpeg', 'heic': 'public.heic',
    'heif': 'public.heif', 'png': 'public.png', 'dng': 'com.adobe.raw-image',
    'raw': 'com.adobe.raw-image', 'cr2': 'com.canon.cr2-raw-image',
    'nef': 'com.nikon.raw-image', 'arw': 'com.sony.raw-image',
    'tif': 'public.tiff', 'tiff': 'public.tiff', 'gif': 'com.compuserve.gif',
    'webp': 'org.webmproject.webp',
}
GENERIC_VIDEO_EXTENSIONS = {
    'mov': 'com.apple.quicktime-movie', 'mp4': 'public.mpeg-4',
    'm4v': 'com.apple.m4v-video',
}


def _generic_media_files(root):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('导入位置必须是普通文件夹')
    files = []
    for path in sorted(root.iterdir(), key=lambda value: value.name):
        if path.name.startswith('.') or path.is_symlink() or not path.is_file():
            continue
        extension = path.suffix.lower().lstrip('.')
        if extension in GENERIC_IMAGE_EXTENSIONS or extension in GENERIC_VIDEO_EXTENSIONS:
            files.append(path)
    if not files:
        raise ValueError('文件夹内没有可导入的照片或视频')
    return files


def _generic_staging_root(source):
    configured = os.environ.get('PHOTOBRIDGE_IMPORT_STAGING_ROOT')
    if configured:
        root = Path(configured)
    else:
        root = Path.home() / 'Library' / 'Application Support' / 'PhotoBridge' / 'ImportSessions'
    return root / hashlib.sha256(str(Path(source).resolve()).encode('utf-8')).hexdigest()[:32]


def prepare_import_backup(local, progress=None):
    """Turn a normal Mac photo folder into an app-private verified backup.

    Existing PhotoBridge backups are returned unchanged. A plain folder is
    read in filename order, while the original folder stays byte-for-byte
    untouched. Internal manifests and hardlinks live in Application Support,
    so the user's folder contains only their own files.
    """
    local = Path(local)
    if local.is_symlink() or not local.is_dir():
        raise ValueError('导入位置必须是普通文件夹')
    if ((local / 'album-order.json').is_file() and (local / 'transfer-manifest.json').is_file()) or (local / '.photobridge-layout.json').is_file():
        return local
    files = _generic_media_files(local)
    if progress:
        progress({'status': 'SCANNING', 'state': 'SCANNING', 'scannedAssets': 0,
                  'scanTotalAssets': len(files), 'currentResource': None,
                  'assetsVerified': 0, 'totalAssets': 0, 'resourcesVerified': 0,
                  'totalResources': 0, 'bytesVerified': 0, 'totalBytes': 0})
    records = []
    fingerprint = hashlib.sha256()
    for scanned, path in enumerate(files, 1):
        hasher = hashlib.sha256(); byte_count = 0
        with path.open('rb') as source:
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk: break
                hasher.update(chunk); byte_count += len(chunk)
        digest = hasher.hexdigest()
        extension_lower = path.suffix.lower().lstrip('.')
        extension = path.suffix.lstrip('.')
        uti = GENERIC_VIDEO_EXTENSIONS.get(extension_lower) or GENERIC_IMAGE_EXTENSIONS.get(extension_lower)
        media_type = 2 if extension_lower in GENERIC_VIDEO_EXTENSIONS else 1
        captured = dt.datetime.fromtimestamp(path.stat().st_mtime, dt.timezone.utc).isoformat().replace('+00:00', 'Z')
        fingerprint.update(path.name.encode('utf-8')); fingerprint.update(b'\0')
        fingerprint.update(str(byte_count).encode('ascii')); fingerprint.update(b'\0'); fingerprint.update(digest.encode('ascii'))
        records.append((path, byte_count, digest, extension, uti, media_type, captured))
        if progress:
            progress({'status': 'SCANNING', 'state': 'SCANNING', 'scannedAssets': scanned,
                      'scanTotalAssets': len(files), 'currentResource': path.name,
                      'assetsVerified': 0, 'totalAssets': 0, 'resourcesVerified': 0,
                      'totalResources': 0, 'bytesVerified': 0, 'totalBytes': 0})
    staging = _generic_staging_root(local)
    if staging.exists():
        try:
            validated_backup(staging)
            return staging
        except Exception:
            shutil.rmtree(staging)
    staging.mkdir(mode=0o700, parents=True, exist_ok=False)
    session = str(uuid.UUID(bytes=hashlib.sha256(fingerprint.digest()).digest()[:16]))
    captured_at = records[0][6]
    album_id = 'mac-folder:' + hashlib.sha256(str(local.resolve()).encode('utf-8')).hexdigest()[:24]
    members = []
    assets = []
    total = 0
    for ordinal, (path, byte_count, digest, extension, uti, media_type, captured) in enumerate(records, 1):
        identifier = f'mac-file:{ordinal}:{path.name}'
        relative = f'Resources/{ordinal:06d}/0001.' + (extension if re.fullmatch(r'[A-Za-z0-9]{1,10}', extension) else 'bin')
        destination = staging / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.link(path, destination, follow_symlinks=False)
        except OSError:
            shutil.copy2(path, destination)
        member = {'ordinal': ordinal, 'localIdentifier': identifier, 'creationDate': captured}
        resource = {'resourceIndex': 1, 'resourceType': media_type, 'originalFilename': path.name,
                    'uniformTypeIdentifier': uti, 'storedRelativePath': relative,
                    'sha256': digest, 'byteCount': byte_count}
        members.append(member)
        assets.append({'ordinal': ordinal, 'resourceGroupId': str(uuid.uuid5(uuid.NAMESPACE_URL, identifier)),
                       'sourceAssetLocalIdentifier': identifier, 'originalPhotoLibraryCreationDate': captured,
                       'pixelWidth': 0, 'pixelHeight': 0, 'mediaType': media_type,
                       'mediaSubtypes': 0, 'resources': [resource]})
        total += byte_count
    source = {'schemaVersion': '1.0.0', 'albumName': local.name or 'Mac 照片', 'albumIdentifier': album_id,
              'authorization': 'full', 'fetchMode': 'mac-folder-filename-order', 'capturedAt': captured_at,
              'systemVersion': 'macOS', 'build': 'generic-folder-import', 'members': members,
              'verification': 'NOT_RUN: order follows Mac filename preview order'}
    manifest = {'schemaVersion': '1.0.0', 'kind': 'PhotoBridgeOriginalExport', 'sessionID': session,
                'sourceOrder': source, 'assets': assets, 'status': 'staged', 'intervalSeconds': 5,
                'timestampScope': 'new-Mac-copies-filesystem-only',
                'restorationStatus': 'NOT_RUN: staged resource backup only'}
    raw = json.dumps(manifest, indent=2, ensure_ascii=False, sort_keys=True).encode('utf-8')
    validate_manifest(manifest)
    (staging / 'source-order.json').write_bytes(json.dumps(source, indent=2, ensure_ascii=False, sort_keys=True).encode('utf-8'))
    (staging / 'album-order.json').write_bytes(raw)
    digest = hashlib.sha256(raw).hexdigest()
    (staging / 'transfer-manifest.json').write_text(json.dumps({'status': 'COMMITTED',
        'sourceManifestSHA256': digest, 'resourcesVerified': len(records), 'bytesVerified': total}, indent=2))
    return staging


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
    resources = [r for a in manifest['assets'] for r in a['resources']]
    digest = hashlib.sha256(raw).hexdigest(); total = sum(r['byteCount'] for r in resources)
    _verify_commit(local, digest, len(resources), total)
    _verify_resources(local, resources, cancel_file)
    return raw, manifest, resources, digest, total


def _verify_commit(local, digest, count, total):
    committed_path = regular_path(local, 'transfer-manifest.json')
    if committed_path.stat().st_size > 64 * 1024 * 1024: raise ValueError('Transfer manifest exceeds bound')
    committed = json.loads(committed_path.read_bytes())
    if (committed.get('status') != 'COMMITTED' or committed.get('sourceManifestSHA256') != digest
            or committed.get('resourcesVerified') != count or committed.get('bytesVerified') != total):
        raise ValueError('Backup is not a matching committed transfer')


def _verify_resources(local, resources, cancel_file):
    for resource in resources:
        check_cancel(cancel_file)
        receipt = inspect(regular_path(local, resource['storedRelativePath']))
        if receipt['sha256'] != resource['sha256'] or receipt['byteCount'] != resource['byteCount']:
            raise ValueError('Local backup byte/hash mismatch')


def revalidate_backup(local, raw, resources, digest, total, cancel_file=None):
    """Recheck the bound bytes and every resource; reuse only already validated metadata.

    Avoid retaining a second huge decoded manifest during final publication. No
    media receipts are cached: all source files are still rehashed each time.
    """
    local = Path(local); path = regular_path(local, 'album-order.json')
    if path.stat().st_size != len(raw) or path.read_bytes() != raw: raise ValueError('Source manifest changed before publication')
    _verify_commit(local, digest, len(resources), total)
    _verify_resources(local, resources, cancel_file)


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
