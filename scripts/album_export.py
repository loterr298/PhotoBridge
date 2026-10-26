#!/usr/bin/env python3
"""Copy PhotoBridge original-resource sessions through USB-only AFC; never touches Photos originals."""
import argparse
import ctypes as C
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import time
import uuid
from usb_probe import AFC, inspect, read_snapshot, reconnectable_read
from transfer_progress import snapshot
from transfer_control import CancellationRequested, check_cancel
from backup_layout import local_path, prepare_flat, is_flat, publish_photo


def set_copy_creation_time(path, nanoseconds):
    """Public Darwin fsetattrlist; called only for our newly verified local copies."""
    if sys.platform != 'darwin': return 'NOT_SET: platform has no Darwin creation-time API'
    class AttrList(C.Structure):
        _fields_ = [('bitmapcount', C.c_uint16), ('reserved', C.c_uint16),
                    ('commonattr', C.c_uint32), ('volattr', C.c_uint32), ('dirattr', C.c_uint32),
                    ('fileattr', C.c_uint32), ('forkattr', C.c_uint32)]
    class Timespec(C.Structure):
        _fields_ = [('seconds', C.c_long), ('nanoseconds', C.c_long)]
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode): raise ValueError('Creation time requires a regular new copy')
        attributes = AttrList(5, 0, 0x00000200, 0, 0, 0, 0)  # ATTR_CMN_CRTIME, public sys/attr.h
        timestamp = Timespec(nanoseconds // 1_000_000_000, nanoseconds % 1_000_000_000)
        system = C.CDLL(None, use_errno=True)
        system.fsetattrlist.argtypes = [C.c_int, C.POINTER(AttrList), C.c_void_p, C.c_size_t, C.c_uint]
        system.fsetattrlist.restype = C.c_int
        if system.fsetattrlist(descriptor, C.byref(attributes), C.byref(timestamp), C.sizeof(timestamp), 0):
            return 'NOT_SET: Darwin errno ' + str(C.get_errno())
        actual = getattr(os.fstat(descriptor), 'st_birthtime', None)
        return 'SET_AND_VERIFIED' if actual is not None and abs(actual - nanoseconds / 1e9) < .001 else 'NOT_VERIFIED'
    finally:
        os.close(descriptor)


def validate_asset_record(asset, member, ordinal):
    def text_fields(value, names):
        if any(not isinstance(value.get(name), str) for name in names):
            raise ValueError('Invalid asset text field')
    def utc(value):
        date = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
        if date.tzinfo is None or date.utcoffset() != dt.timedelta(0):
            raise ValueError('Date must specify UTC')
    paths = []
    identifier = member['localIdentifier']; group = asset['resourceGroupId']
    text_fields(member, ['localIdentifier']); text_fields(asset, ['resourceGroupId', 'sourceAssetLocalIdentifier'])
    for value in [member.get('creationDate'), asset.get('originalPhotoLibraryCreationDate')]:
        if value is not None: utc(value)
    source_date = member.get('creationDate'); asset_date = asset.get('originalPhotoLibraryCreationDate')
    if (source_date is None) != (asset_date is None) or (source_date is not None and
            dt.datetime.fromisoformat(source_date.replace('Z', '+00:00')) != dt.datetime.fromisoformat(asset_date.replace('Z', '+00:00'))):
        raise ValueError('Source and asset creation date differ')
    if any(type(asset.get(key)) is not int or not 0 <= asset[key] <= (2**64 - 1 if key == 'mediaSubtypes' else 2**63 - 1)
           for key in ['pixelWidth', 'pixelHeight', 'mediaType', 'mediaSubtypes']):
        raise ValueError('Missing or invalid asset media metadata')
    if type(member['ordinal']) is not int or type(asset['ordinal']) is not int or not isinstance(asset['resources'], list):
        raise ValueError('Invalid ordinal/resources type')
    uuid.UUID(group)
    if (not identifier
            or member['ordinal'] != ordinal or asset['ordinal'] != ordinal
            or asset['sourceAssetLocalIdentifier'] != identifier or not asset['resources']):
        raise ValueError('Invalid order, duplicate or missing resource group')

    for index, resource in enumerate(asset['resources'], 1):
        text_fields(resource, ['originalFilename', 'uniformTypeIdentifier', 'storedRelativePath', 'sha256'])
        if not resource['uniformTypeIdentifier']: raise ValueError('Missing resource type identifier')
        # Only the safe extension is derived from the original filename, never its path.
        ext = PurePosixPath(resource['originalFilename']).suffix[1:]
        ext = ext if re.fullmatch(r'[A-Za-z0-9]{1,10}', ext) else 'bin'
        path = resource['storedRelativePath']
        expected = f'Resources/{ordinal:06d}/{index:04d}.{ext}'
        if (type(resource['resourceIndex']) is not int or resource['resourceIndex'] != index or path != expected
                or type(resource['byteCount']) is not int or not 0 < resource['byteCount'] <= 2**63 - 1
                or type(resource['resourceType']) is not int or not 0 < resource['resourceType'] <= 2**63 - 1
                or not re.fullmatch(r'[a-f0-9]{64}', resource['sha256'])):
            raise ValueError('Invalid resource path, size, type or SHA-256')
        paths.append(path)
    return paths


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
        asset_paths = validate_asset_record(asset, member, ordinal)
        identifier = member['localIdentifier']; group = asset['resourceGroupId']
        if identifier in identifiers or group in groups or any(path in paths for path in asset_paths):
            raise ValueError('Duplicate asset, group or resource path')
        identifiers.add(identifier); groups.add(group); paths.update(asset_paths)


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
        temporary = path.with_name('.photobridge-progress-' + str(uuid.uuid4()) + '.tmp')
        with temporary.open('x') as f: json.dump(value, f, indent=2, ensure_ascii=False); f.flush(); os.fsync(f.fileno())
        os.replace(temporary, path)


def copy_resource(client, remote, local, resource, logical):
    destination = local_path(local, resource['storedRelativePath']); destination.parent.mkdir(parents=True, exist_ok=True)
    part = destination.with_name(destination.name + '.part')
    for attempt in range(3):
        try:
            with part.open('xb') as f:
                client.read(remote + '/' + resource['storedRelativePath'], f.write, resource['byteCount'])
                f.flush(); os.fsync(f.fileno())
            break
        except RuntimeError as error:
            if attempt == 2 or not reconnectable_read(error) or not hasattr(client, 'reconnect'): raise
            client.reconnect()
            # Preserve the failed attempt; never append duplicated bytes or truncate it.
            part = destination.with_name(destination.name + '.' + str(uuid.uuid4()) + '.part')
    actual = inspect(part)
    if actual['sha256'] != resource['sha256'] or actual['byteCount'] != resource['byteCount']:
        raise ValueError('Resource size / SHA-256 mismatch; partial retained')
    before = part.stat()
    # Exclusive local commit. The .part hard link stays as a diagnostic trace, not a second copy.
    os.link(part, destination)
    os.utime(destination, ns=(before.st_atime_ns, int(logical.timestamp() * 1_000_000_000)), follow_symlinks=False)
    creation_status = set_copy_creation_time(destination, int(logical.timestamp() * 1_000_000_000))
    after = destination.stat(); verified = inspect(destination)
    if verified['sha256'] != resource['sha256'] or abs(after.st_mtime - logical.timestamp()) > .001:
        raise ValueError('Post-attribute byte/time verification failed')
    change = {'path': resource['storedRelativePath'],
        'oldMtimeNs': before.st_mtime_ns, 'newMtimeNs': after.st_mtime_ns,
        'oldBirthtime': getattr(before, 'st_birthtime', None),
        'newBirthtime': getattr(after, 'st_birthtime', None),
        'creationTimeStatus': creation_status,
        'logicalSortTimeUtc': logical.isoformat(), 'contentSHA256Unchanged': True}
    return change, actual


def download_album(client, remote, local, cancel_file=None):
    remote = session_path(remote); local = Path(local)
    check_cancel(cancel_file)
    if local.exists() or local.is_symlink(): raise FileExistsError(local)
    raw = io.BytesIO(); client.read(remote + '/album-order.json', raw.write, 64 * 1024 * 1024)
    m = json.loads(raw.getvalue()); validate_manifest(m)
    if m['sessionID'].lower() != remote.split('/')[1].lower(): raise ValueError('Session identity mismatch')
    local.mkdir(mode=0o700, parents=True, exist_ok=False)
    resources = [resource for asset in m['assets'] for resource in asset['resources']]
    total_bytes = sum(resource['byteCount'] for resource in resources)
    manifest_digest = hashlib.sha256(raw.getvalue()).hexdigest()
    start = time.monotonic()
    progress = snapshot(status='DOWNLOADING', started_monotonic=start, now_monotonic=start,
                        resources_verified=0, total_resources=len(resources),
                        bytes_verified=0, total_bytes=total_bytes)
    progress.update({'sourceManifestSHA256': manifest_digest,
                     'restoration': 'NOT_RUN', 'filesystemAttributeLog': 'filesystem-attributes.jsonl'})
    journal = local / 'transfer-progress.json'
    write_json(journal, progress)
    base = dt.datetime.fromisoformat(m['sourceOrder']['capturedAt'].replace('Z', '+00:00'))
    changes = []
    attribute_log = (local / 'filesystem-attributes.jsonl').open('x')
    try:
        for asset in m['assets']:
            logical = base + dt.timedelta(seconds=(asset['ordinal'] - 1) * 5)
            for resource in asset['resources']:
                check_cancel(cancel_file)
                progress.update(snapshot(status='DOWNLOADING', started_monotonic=start, now_monotonic=time.monotonic(),
                                         resources_verified=progress['resourcesVerified'],
                                         total_resources=len(resources), bytes_verified=progress['bytesVerified'],
                                         total_bytes=total_bytes, current_resource=resource['storedRelativePath']))
                progress['sourceManifestSHA256'] = manifest_digest
                progress['restoration'] = 'NOT_RUN'
                progress['filesystemAttributeLog'] = 'filesystem-attributes.jsonl'
                write_json(journal, progress)
                change, actual = copy_resource(client, remote, local, resource, logical)
                attribute_log.write(json.dumps(change) + '\n'); attribute_log.flush(); os.fsync(attribute_log.fileno())
                changes.append(change)
                progress.update(snapshot(status='DOWNLOADING', started_monotonic=start, now_monotonic=time.monotonic(),
                                         resources_verified=progress['resourcesVerified'] + 1,
                                         total_resources=len(resources), bytes_verified=progress['bytesVerified'] + actual['byteCount'],
                                         total_bytes=total_bytes, current_resource=resource['storedRelativePath']))
                progress['sourceManifestSHA256'] = manifest_digest
                progress['restoration'] = 'NOT_RUN'
                progress['filesystemAttributeLog'] = 'filesystem-attributes.jsonl'
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
    except CancellationRequested as error:
        progress['status'] = 'STOPPED'; progress['error'] = str(error)
        write_json(journal, progress)
        raise
    except Exception as error:
        progress['status'] = 'FAILED'; progress['error'] = str(error)
        write_json(journal, progress)
        raise
    finally:
        attribute_log.close()


def download_live_album(client, request_id, album_identifier, local, cancel_file=None, idle_timeout=1800, previous=None, flat=False, status_interval=.25, progress_callback=None):
    """Receive published asset records immediately, then bind them to the final manifest.

    Photos bytes never enter the control channel. A record is only published by
    iOS after all of that asset's resources are closed and hashed. No final
    backup is declared until the full album has been rechecked on iOS.
    """
    if str(uuid.UUID(request_id)).lower() != request_id.lower(): raise ValueError('Invalid request ID')
    check_cancel(cancel_file)
    local = Path(local)
    if local.exists() or local.is_symlink(): raise FileExistsError(local)
    if previous is not None:
        previous = Path(previous)
        from album_restore import regular_path
        previous_progress = json.loads(regular_path(previous, 'transfer-progress.json').read_bytes())
        if previous_progress.get('albumIdentifier') != album_identifier:
            raise ValueError('Previous export belongs to a different album')
        if previous.resolve() == local.resolve() or previous.resolve() in local.resolve().parents:
            raise ValueError('Continuation must preserve the previous directory')
    local.mkdir(mode=0o700, parents=True, exist_ok=False)
    if flat: prepare_flat(local)
    start = time.monotonic(); last_activity = start; previous_activity = None
    progress = dict(status='WAITING_FOR_IPHONE', requestID=request_id, assetsVerified=0,
                    albumIdentifier=album_identifier, reusedVerifiedResources=0, totalAssets=0, resourcesVerified=0, bytesVerified=0, totalResources=0,
                    totalBytes=0, restoration='NOT_RUN', message='正在连接 iPhone…')
    journal = local_path(local, 'transfer-progress.json')
    def report():
        total = progress['totalAssets']
        done = progress['assetsVerified']
        progress['percent'] = (100 if progress['status'] == 'COMMITTED' else min(99, done * 100 // total)) if total else None
        write_json(journal, progress)
        if progress_callback: progress_callback(progress)
    report()

    def read_optional(path, maximum=64 * 1024 * 1024):
        try: return read_snapshot(client, path, maximum)
        except RuntimeError as error:
            # Only a genuinely absent file is pending. Trust, unplug, permission,
            # malformed JSON and other transport failures surface immediately.
            if str(error).endswith(': error 8'): return None
            raise

    last_poll = float("-inf"); last_job = None
    def job(force=False):
        nonlocal last_activity, previous_activity, last_poll, last_job
        check_cancel(cancel_file)
        now = time.monotonic()
        if not force and last_job is not None and now - last_poll < status_interval:
            return last_job
        raw = read_optional('Control/Jobs/' + request_id + '.json', 1024 * 1024)
        if raw is None:
            value = {}
        else:
            value = json.loads(raw)
            if value.get('requestID') != request_id or value.get('albumIdentifier') != album_identifier:
                raise ValueError('iPhone request identity mismatch; refusing stale session')
            if value.get('status') in ('FAILED', 'STOPPED', 'INTERRUPTED'):
                raise RuntimeError(value.get('error') or value.get('message') or 'iPhone export stopped')
            activity = (value.get('status'), value.get('resourcesCompleted'), value.get('scannedAssets'))
            if activity != previous_activity:
                last_activity = time.monotonic(); previous_activity = activity
            progress['message'] = value.get('message', '正在读取相册…')
            progress['scannedAssets'] = value.get('scannedAssets', 0)
            progress['scanTotalAssets'] = value.get('scanTotalAssets', 0)
            if type(value.get('phoneInForeground')) is bool:
                progress['phoneInForeground'] = value['phoneInForeground']
        if time.monotonic() - last_activity > idle_timeout:
            raise TimeoutError('iPhone 长时间没有新进度，请保持手机解锁并打开 PhotoBridge')
        report()
        last_poll = now; last_job = value
        return value

    def wait_file(path):
        while True:
            job()
            raw = read_optional(path)
            if raw is not None: return raw
            time.sleep(.3)

    try:
        while True:
            status = job()
            session = status.get('sessionID')
            if session:
                remote = session_path('Exports/' + session)
                progress['remote'] = remote
                break
            time.sleep(.3)
        source_raw = wait_file(remote + '/source-order.json')
        source = json.loads(source_raw)
        if source.get('albumIdentifier') != album_identifier or source.get('authorization') != 'full':
            raise ValueError('Source album identity or Photos permission mismatch')
        members = source['members']
        if not isinstance(members, list) or not members: raise ValueError('Empty album')
        identifiers = set()
        for ordinal, member in enumerate(members, 1):
            identifier = member['localIdentifier']
            if type(member['ordinal']) is not int or member['ordinal'] != ordinal or not isinstance(identifier, str) or not identifier or identifier in identifiers:
                raise ValueError('Invalid source album positions')
            identifiers.add(identifier)
        base = dt.datetime.fromisoformat(source['capturedAt'].replace('Z', '+00:00'))
        if base.tzinfo is None or base.utcoffset() != dt.timedelta(0): raise ValueError('Source date must be UTC')
        with (local_path(local, 'source-order.json')).open('xb') as f: f.write(source_raw)
        progress['totalAssets'] = len(members)
        groups = set(); record_digests = []
        if not flat: (local / 'asset-records').mkdir()
        with (local_path(local, 'filesystem-attributes.jsonl')).open('x') as attribute_log:
            for ordinal, member in enumerate(members, 1):
                progress['status'] = 'WAITING_FOR_PHOTO'
                raw = wait_file(remote + f'/asset-records/{ordinal:06d}.json')
                asset = json.loads(raw); validate_asset_record(asset, member, ordinal)
                if asset['resourceGroupId'] in groups: raise ValueError('Duplicate resource group')
                groups.add(asset['resourceGroupId'])
                logical = base + dt.timedelta(seconds=(ordinal - 1) * 5)
                for resource in asset['resources']:
                    job()
                    progress.update(status='DOWNLOADING', currentResource=resource['originalFilename'])
                    report()
                    reader = client
                    if previous is not None and (local_path(previous, resource['storedRelativePath']).exists() or local_path(previous, resource['storedRelativePath']).is_symlink()):
                        old = regular_path(previous, resource['storedRelativePath'])
                        receipt = inspect(old)
                        if receipt['sha256'] != resource['sha256'] or receipt['byteCount'] != resource['byteCount']:
                            raise ValueError('Previously saved photo differs; refusing reuse')
                        class LocalReader:
                            def read(self, path, sink, maximum=None):
                                with old.open('rb') as f:
                                    while True:
                                        data = f.read(1024 * 1024)
                                        if not data: break
                                        sink(data)
                        reader = LocalReader()
                        progress['reusedVerifiedResources'] += 1
                    change, actual = copy_resource(reader, remote, local, resource, logical)
                    attribute_log.write(json.dumps(change) + '\n'); attribute_log.flush(); os.fsync(attribute_log.fileno())
                    progress['resourcesVerified'] += 1; progress['bytesVerified'] += actual['byteCount']
                    progress['bytesPerSecond'] = progress['bytesVerified'] / max(.001, time.monotonic() - start)
                    last_activity = time.monotonic()
                with local_path(local, f'asset-records/{ordinal:06d}.json').open('xb') as f: f.write(raw)
                publish_photo(local, asset)
                record_digests.append(hashlib.sha256(json.dumps(asset, sort_keys=True).encode()).digest())
                progress['assetsVerified'] = ordinal
                report()
        progress['status'] = 'FINALIZING'; report()
        final_raw = wait_file(remote + '/album-order.json')
        final = json.loads(final_raw); validate_manifest(final)
        if final['sessionID'] != session or final['sourceOrder'] != source:
            raise ValueError('Final source manifest changed')
        if len(final['assets']) != len(record_digests) or any(
                hashlib.sha256(json.dumps(asset, sort_keys=True).encode()).digest() != digest
                for asset, digest in zip(final['assets'], record_digests)):
            raise ValueError('Final manifest does not match transferred records')
        final_check = wait_file(remote + '/album-order.json')
        if final_check != final_raw: raise ValueError('Final manifest changed during verification')
        job(force=True)  # A cached status must never conceal a failure at publication.
        with (local_path(local, 'album-order.json')).open('xb') as f:
            f.write(final_raw); f.flush(); os.fsync(f.fileno())
        progress.update(status='COMMITTED', totalResources=progress['resourcesVerified'],
                        totalBytes=progress['bytesVerified'], sourceManifestSHA256=hashlib.sha256(final_raw).hexdigest(),
                        seconds=time.monotonic() - start, message='全部照片已保存并校验')
        write_json(local_path(local, 'transfer-manifest.json'), progress, exclusive=True)
        report()
        return progress
    except Exception as error:
        progress.update(status='STOPPED' if isinstance(error, CancellationRequested) else 'FAILED', error=str(error))
        report()
        raise



def organize_local_album(previous, local, cancel_file=None):
    """Copy a complete or interrupted local export to a NEW flat album, offline."""
    from album_restore import regular_path, validated_backup
    previous = Path(previous); local = Path(local)
    if local.exists() or local.is_symlink(): raise FileExistsError(local)
    old_root = previous.resolve(strict=True); new_root = local.resolve()
    if old_root == new_root or old_root in new_root.parents or new_root in old_root.parents:
        raise ValueError('Organization must preserve the previous directory')
    check_cancel(cancel_file)
    try: old_progress = json.loads(regular_path(previous,'transfer-progress.json').read_bytes())
    except FileNotFoundError: old_progress = {}  # A committed legacy backup may omit its live progress journal.
    manifest_path = local_path(previous,'album-order.json')
    full_raw = None
    if manifest_path.exists() or manifest_path.is_symlink():
        full_raw, manifest, _, _, _ = validated_backup(previous)
        source = manifest['sourceOrder']; assets = manifest['assets']
    else:
        source = json.loads(regular_path(previous,'source-order.json').read_bytes())
        count = old_progress.get('assetsVerified')
        if type(count) is not int or not 0 <= count <= len(source['members']):
            raise ValueError('Missing verified asset count; refusing to guess order')
        assets = [json.loads(regular_path(previous,f'asset-records/{i:06d}.json').read_bytes()) for i in range(1,count+1)]
    if source.get('authorization') != 'full' or not source.get('albumIdentifier'):
        raise ValueError('Invalid original album identity/permission')
    base = dt.datetime.fromisoformat(source['capturedAt'].replace('Z','+00:00'))
    if base.tzinfo is None or base.utcoffset() != dt.timedelta(0): raise ValueError('Source time must be UTC')
    for ordinal,asset in enumerate(assets,1): validate_asset_record(asset,source['members'][ordinal-1],ordinal)
    local.mkdir(mode=0o700,parents=True,exist_ok=False);prepare_flat(local)
    progress = dict(old_progress,status='COPYING_LOCAL',albumIdentifier=source['albumIdentifier'],
        assetsVerified=0,totalAssets=len(source['members']),resourcesVerified=0,bytesVerified=0,
        reusedVerifiedResources=0,restoration='NOT_RUN',localOrganization=True)
    for key in ('error','bytesPerSecond','etaSeconds','seconds','MiBPerSecondIncludingVerification','currentResource','message'):
        progress.pop(key,None)
    progress['sourcePreviousState'] = old_progress.get('status')
    journal = local_path(local,'transfer-progress.json');write_json(journal,progress)
    with local_path(local,'source-order.json').open('xb') as f:f.write(json.dumps(source).encode())
    try:
        with local_path(local,'filesystem-attributes.jsonl').open('x') as changes:
            for ordinal,asset in enumerate(assets,1):
                logical = base + dt.timedelta(seconds=(ordinal-1)*5)
                for resource in asset['resources']:
                    check_cancel(cancel_file)
                    old = regular_path(previous,resource['storedRelativePath'])
                    progress['currentResource'] = resource['originalFilename']
                    class LocalReader:
                        def read(self,path,sink,maximum=None):
                            with old.open('rb') as f:
                                while True:
                                    data=f.read(1024*1024)
                                    if not data:break
                                    sink(data)
                    change,actual=copy_resource(LocalReader(),'local-copy',local,resource,logical)
                    changes.write(json.dumps(change)+'\n');changes.flush();os.fsync(changes.fileno())
                    progress['resourcesVerified']+=1;progress['bytesVerified']+=actual['byteCount']
                with local_path(local,f'asset-records/{ordinal:06d}.json').open('xb') as f:f.write(json.dumps(asset).encode())
                publish_photo(local,asset);progress['assetsVerified']=ordinal;write_json(journal,progress)
        if full_raw is not None:
            if regular_path(previous,'album-order.json').read_bytes()!=full_raw:raise ValueError('Previous manifest changed')
            with local_path(local,'album-order.json').open('xb') as f:f.write(full_raw);f.flush();os.fsync(f.fileno())
            progress.update(status='COMMITTED',sourceManifestSHA256=hashlib.sha256(full_raw).hexdigest())
            write_json(local_path(local,'transfer-manifest.json'),progress,exclusive=True)
        else:
            progress['status']='STOPPED'  # A partial local copy must never claim a complete backup.
        progress['message'] = f'已整理 {len(assets)} 张照片' + ('，剩余照片可继续导出' if full_raw is None else '')
        write_json(journal,progress);return progress
    except Exception as error:
        progress.update(status='STOPPED' if isinstance(error,CancellationRequested) else 'FAILED',error=str(error))
        write_json(journal,progress);raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['list', 'download', 'live', 'organize'])
    parser.add_argument('--bundle', default='com.photobridge.OrderProbe')
    parser.add_argument('--previous', type=Path); parser.add_argument('--request-id'); parser.add_argument('--album-id'); parser.add_argument('--remote'); parser.add_argument('--local', type=Path)
    parser.add_argument('--flat', action='store_true')
    parser.add_argument('--cancel-file', type=Path)
    args = parser.parse_args(); client = None
    try:
        if args.command == 'organize':
            result = organize_local_album(args.previous, args.local, args.cancel_file)
            print(json.dumps(result, indent=2)); return 0
        client = AFC(); client.vend(args.bundle)
        if args.command == 'list': result = {'status': 'DISCOVERED', 'sessions': client.list('Exports')}
        elif args.command == 'live':
            if not args.request_id or not args.album_id or args.local is None: raise ValueError('Missing live export arguments')
            from transfer_progress import ProgressRelay
            relay = ProgressRelay(client, args.request_id, 'TO_MAC')
            result = download_live_album(client, args.request_id, args.album_id, args.local, args.cancel_file, previous=args.previous, flat=args.flat, progress_callback=relay)
        else:
            if not args.remote or args.local is None: raise ValueError('--remote and NEW --local directory required')
            result = download_album(client, args.remote, args.local, args.cancel_file)
            # Private paths and all detailed media attributes stay in the local report, never CI.
            result = {k: result[k] for k in ['status', 'resourcesVerified', 'bytesVerified', 'seconds', 'MiBPerSecondIncludingVerification']}
        print(json.dumps(result, indent=2)); return 0
    except CancellationRequested as error:
        print(json.dumps({'status': 'STOPPED', 'error': str(error)})); return 3
    except Exception as error:
        print(json.dumps({'status': 'FAILED', 'error': str(error)})); return 2
    finally:
        if client: client.close()


if __name__ == '__main__': sys.exit(main())
