#!/usr/bin/env python3
"""Copy PhotoBridge original-resource sessions through USB-only AFC; never touches Photos originals."""
import argparse
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
import time
import uuid
from usb_probe import AFC, inspect


def validate_manifest(m):
    def text_fields(value, names):
        if any(not isinstance(value.get(name), str) for name in names):
            raise ValueError('Missing or invalid manifest text field')
    def utc(value):
        if not isinstance(value, str): raise ValueError('Invalid date')
        date = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
        if date.tzinfo is None or date.utcoffset() != dt.timedelta(0): raise ValueError('Date must specify UTC')
        return date
    text_fields(m, ['schemaVersion', 'kind', 'sessionID', 'status', 'timestampScope', 'restorationStatus'])
    if (m.get('schemaVersion') != '1.0.0' or m.get('kind') != 'PhotoBridgeOriginalExport'
            or m.get('status') != 'staged' or m.get('intervalSeconds') != 5
            or m.get('timestampScope') != 'new-Mac-copies-filesystem-only'):
        raise ValueError('Unsupported manifest or timestamp policy')
    uuid.UUID(m['sessionID'])
    source = m['sourceOrder']; members = source['members']; assets = m['assets']
    text_fields(source, ['schemaVersion', 'albumName', 'albumIdentifier', 'authorization', 'fetchMode',
                         'capturedAt', 'systemVersion', 'build', 'verification'])
    if source['schemaVersion'] != '1.0.0' or not source['albumIdentifier'] or not m['restorationStatus'].startswith('NOT_RUN'):
        raise ValueError('Invalid source identity/schema or restoration claim')
    if not isinstance(members, list) or not isinstance(assets, list): raise ValueError('Invalid asset/member arrays')
    if source['authorization'] != 'full' or not members or len(members) != len(assets):
        raise ValueError('Incomplete album or insufficient permission')
    utc(source['capturedAt'])
    paths = set(); identifiers = set(); groups = set()
    for ordinal, (member, asset) in enumerate(zip(members, assets), 1):
        identifier = member['localIdentifier']; group = asset['resourceGroupId']
        text_fields(member, ['localIdentifier']); text_fields(asset, ['resourceGroupId', 'sourceAssetLocalIdentifier'])
        for value in [member.get('creationDate'), asset.get('originalPhotoLibraryCreationDate')]:
            if value is not None: utc(value)
        if any(type(asset.get(key)) is not int or not 0 <= asset[key] <= (2**64 - 1 if key == 'mediaSubtypes' else 2**63 - 1)
               for key in ['pixelWidth', 'pixelHeight', 'mediaType', 'mediaSubtypes']):
            raise ValueError('Missing or invalid asset media metadata')
        if type(member['ordinal']) is not int or type(asset['ordinal']) is not int or not isinstance(asset['resources'], list):
            raise ValueError('Invalid ordinal/resources type')
        uuid.UUID(group)
        if (not identifier or identifier in identifiers or group in groups
                or member['ordinal'] != ordinal or asset['ordinal'] != ordinal
                or asset['sourceAssetLocalIdentifier'] != identifier or not asset['resources']):
            raise ValueError('Invalid order, duplicate or missing resource group')
        identifiers.add(identifier); groups.add(group)
        for index, resource in enumerate(asset['resources'], 1):
            text_fields(resource, ['originalFilename', 'uniformTypeIdentifier', 'storedRelativePath', 'sha256'])
            if not resource['uniformTypeIdentifier']: raise ValueError('Missing resource type identifier')
            # Only the safe extension is derived from the original filename, never its path.
            ext = PurePosixPath(resource['originalFilename']).suffix[1:]
            ext = ext if re.fullmatch(r'[A-Za-z0-9]{1,10}', ext) else 'bin'
            path = resource['storedRelativePath']
            expected = f'Resources/{ordinal:06d}/{index:04d}.{ext}'
            if (type(resource['resourceIndex']) is not int or resource['resourceIndex'] != index or path != expected or path in paths
                    or type(resource['byteCount']) is not int or not 0 < resource['byteCount'] <= 2**63 - 1
                    or type(resource['resourceType']) is not int or not 0 < resource['resourceType'] <= 2**63 - 1
                    or not re.fullmatch(r'[a-f0-9]{64}', resource['sha256'])):
                raise ValueError('Invalid resource path, size, type or SHA-256')
            paths.add(path)


def session_path(value):
    parts = value.split('/')
    if len(parts) != 2 or parts[0] != 'Exports' or str(uuid.UUID(parts[1])) != parts[1].lower():
        raise ValueError('Expected Exports/<UUID>')
    return value


def write_json(path, value, exclusive=False):
    if exclusive:
        temporary = path.with_name(path.name + '.' + str(uuid.uuid4()) + '.part')
        with temporary.open('x') as f: json.dump(value, f, indent=2, ensure_ascii=False); f.flush(); os.fsync(f.fileno())
        os.link(temporary, path)  # Atomic exclusive commit; never replace another session's output.
    else:
        # This is our progress file in our exclusively created session, never a user resource.
        temporary = path.with_name('progress-' + str(uuid.uuid4()) + '.tmp')
        with temporary.open('x') as f: json.dump(value, f, indent=2, ensure_ascii=False); f.flush(); os.fsync(f.fileno())
        os.replace(temporary, path)


def download_album(client, remote, local):
    remote = session_path(remote); local = Path(local)
    if local.exists() or local.is_symlink(): raise FileExistsError(local)
    raw = io.BytesIO(); client.read(remote + '/album-order.json', raw.write, 64 * 1024 * 1024)
    m = json.loads(raw.getvalue()); validate_manifest(m)
    if m['sessionID'].lower() != remote.split('/')[1].lower(): raise ValueError('Session identity mismatch')
    local.mkdir(parents=True, exist_ok=False)
    progress = {'status': 'DOWNLOADING', 'resourcesVerified': 0, 'bytesVerified': 0,
                'sourceManifestSHA256': hashlib.sha256(raw.getvalue()).hexdigest(),
                'restoration': 'NOT_RUN', 'filesystemAttributeLog': 'filesystem-attributes.jsonl'}
    journal = local / 'transfer-progress.json'; start = time.monotonic()
    write_json(journal, progress)
    base = dt.datetime.fromisoformat(m['sourceOrder']['capturedAt'].replace('Z', '+00:00'))
    changes = []
    attribute_log = (local / 'filesystem-attributes.jsonl').open('x')
    try:
        for asset in m['assets']:
            logical = base + dt.timedelta(seconds=(asset['ordinal'] - 1) * 5)
            for resource in asset['resources']:
                destination = local / resource['storedRelativePath']; destination.parent.mkdir(parents=True, exist_ok=True)
                part = destination.with_name(destination.name + '.part')
                with part.open('xb') as f:
                    client.read(remote + '/' + resource['storedRelativePath'], f.write, resource['byteCount'])
                    f.flush(); os.fsync(f.fileno())
                actual = inspect(part)
                if actual['sha256'] != resource['sha256'] or actual['byteCount'] != resource['byteCount']:
                    raise ValueError('Resource size / SHA-256 mismatch; partial retained')
                before = part.stat()
                # Exclusive local commit. The .part hard link stays as a diagnostic trace, not a second copy.
                os.link(part, destination)
                os.utime(destination, ns=(before.st_atime_ns, int(logical.timestamp() * 1_000_000_000)), follow_symlinks=False)
                after = destination.stat(); verified = inspect(destination)
                if verified['sha256'] != resource['sha256'] or abs(after.st_mtime - logical.timestamp()) > .001:
                    raise ValueError('Post-attribute byte/time verification failed')
                change = {'path': resource['storedRelativePath'],
                    'oldMtimeNs': before.st_mtime_ns, 'newMtimeNs': after.st_mtime_ns,
                    'oldBirthtime': getattr(before, 'st_birthtime', None),
                    'newBirthtime': getattr(after, 'st_birthtime', None),
                    'creationTimeStatus': 'NOT_SET: creation-time API not implemented',
                    'logicalSortTimeUtc': logical.isoformat(), 'contentSHA256Unchanged': True}
                attribute_log.write(json.dumps(change) + '\n'); attribute_log.flush(); os.fsync(attribute_log.fileno())
                changes.append(change)
                progress['resourcesVerified'] += 1; progress['bytesVerified'] += actual['byteCount']
                write_json(journal, progress)
        # Ensure the phone manifest did not change while copying resources.
        final = io.BytesIO(); client.read(remote + '/album-order.json', final.write, 64 * 1024 * 1024)
        if final.getvalue() != raw.getvalue(): raise ValueError('Source manifest changed during transfer')
        with (local / 'album-order.json').open('xb') as f:
            f.write(raw.getvalue()); f.flush(); os.fsync(f.fileno())
        progress['status'] = 'VERIFIED'; progress['seconds'] = time.monotonic() - start
        progress['MiBPerSecondIncludingVerification'] = progress['bytesVerified'] / 1048576 / progress['seconds']
        write_json(journal, progress)
        result = dict(progress, status='COMMITTED', filesystemAttributeChanges=changes)
        write_json(local / 'transfer-manifest.json', result, exclusive=True)
        return result
    except Exception as error:
        progress['status'] = 'FAILED'; progress['error'] = str(error)
        write_json(journal, progress)
        raise
    finally:
        attribute_log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['list', 'download'])
    parser.add_argument('--bundle', default='com.photobridge.OrderProbe')
    parser.add_argument('--remote'); parser.add_argument('--local', type=Path)
    args = parser.parse_args(); client = None
    try:
        client = AFC(); client.vend(args.bundle)
        if args.command == 'list': result = {'status': 'DISCOVERED', 'sessions': client.list('Exports')}
        else:
            if not args.remote or args.local is None: raise ValueError('--remote and NEW --local directory required')
            result = download_album(client, args.remote, args.local)
            # Private paths and all detailed media attributes stay in the local report, never CI.
            result = {k: result[k] for k in ['status', 'resourcesVerified', 'bytesVerified', 'seconds', 'MiBPerSecondIncludingVerification']}
        print(json.dumps(result, indent=2)); return 0
    except Exception as error:
        print(json.dumps({'status': 'FAILED', 'error': str(error)})); return 2
    finally:
        if client: client.close()


if __name__ == '__main__': sys.exit(main())
