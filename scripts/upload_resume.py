#!/usr/bin/env python3
"""Verified continuation of owned, unpublished App inbox uploads; never performs Photos changes."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import sys
import time
import uuid
from album_restore import regular_path, validated_backup, revalidate_backup
from album_export import write_json
from usb_probe import AFC
from transfer_control import CancellationRequested, check_cancel
from transfer_progress import snapshot
from backup_layout import upload_journals, upload_journal_name


def upload(client, local, previous_journal=None, cancel_file=None, journal_id=None):
    local = Path(local)
    identity = journal_id if journal_id is not None else str(uuid.uuid4()).upper()
    if str(uuid.UUID(identity)).upper() != identity: raise ValueError('Invalid upload journal identity')
    check_cancel(cancel_file)
    raw, manifest, resources, digest, total = validated_backup(local, cancel_file=cancel_file)
    if previous_journal is not None:
        path = Path(previous_journal)
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024: raise ValueError('Invalid upload journal')
        previous = json.loads(path.read_bytes()); owner = previous['owner']; remote = previous['remote']
        if owner['sourceManifestSHA256'] != digest: raise ValueError('Source manifest changed')
        session = owner['sessionID']
        if (remote != 'RestoreInbox/' + session or str(uuid.UUID(session)) != session.lower()
                or owner['kind'] != 'PhotoBridgeUploadOwner' or owner['schemaVersion'] != '1.0.0'):
            raise ValueError('Invalid upload owner/session')
        uuid.UUID(owner['nonce'])
    else:
        session = str(uuid.uuid4()).upper(); remote = 'RestoreInbox/' + session
        owner = dict(kind='PhotoBridgeUploadOwner', schemaVersion='1.0.0', sessionID=session,
            sourceManifestSHA256=digest, nonce=str(uuid.uuid4()))
    owner_raw = json.dumps(owner, sort_keys=True).encode()
    journals = upload_journals(local)
    if journals.is_symlink(): raise ValueError('Journal symlink rejected')
    journals.mkdir(mode=0o700, exist_ok=True)
    journal = journals / upload_journal_name(local, identity)
    journal_owned = False
    resource_names = {r['storedRelativePath']: r['originalFilename'] for r in resources}
    start = time.monotonic()
    state = dict(totalResources=len(resources), totalBytes=total, state='UPLOADING', remote=remote, owner=owner, resourcesVerified=0, bytesVerified=0,
        reusedVerifiedResources=0, resumedPartialBytes=0, usbResourceBytesWritten=0,
        usbVerificationBytesRead=0, photosImport='NOT_RUN', previousLocalJournalWritten=False)
    directory_names = {}

    def names(path):
        # Resource directories are immutable to cooperating writers under the session lock.
        # Avoid listing all asset directories once for every asset in large albums.
        if path == remote: return set(client.list(path))
        if path not in directory_names: directory_names[path] = set(client.list(path))
        return directory_names[path]

    def regular(path, directory=False):
        info = client.info(path)
        if info.get('st_ifmt') != ('S_IFDIR' if directory else 'S_IFREG'):
            raise ValueError('Remote symlink/nonregular path rejected')
        if not directory and info.get('st_nlink') != '1': raise ValueError('Remote multiply-linked file rejected')
        return int(info['st_size'])

    def unpublished():
        names = client.list(remote)
        if 'restore-request.json' in names or 'restore-started.json' in names:
            raise ValueError('Published or attempted Photos session cannot be continued')

    def check(relative, source, size, sha, prefix=False):
        count = 0; h = hashlib.sha256()
        def sink(data):
            nonlocal count
            if prefix and source.read(len(data)) != data: raise ValueError('Partial prefix differs from local source')
            count += len(data); h.update(data); state['usbVerificationBytesRead'] += len(data)
        client.read(remote + '/' + relative, sink, size)
        if not prefix and (count != size or h.hexdigest() != sha): raise ValueError('USB readback hash/size mismatch')
        return count

    try:
        if previous_journal is None:
            write_json(journal, state, exclusive=True)
            journal_owned = True
            client.mkdir('RestoreInbox'); regular('RestoreInbox', True); client.mkdir(remote, exclusive=True)
            regular(remote, True)
            client.write_new(remote + '/upload-owner.json', io.BytesIO(owner_raw))
        else:
            regular(remote, True); regular('RestoreInbox', True)
        regular(remote + '/upload-owner.json')
        with client.locked_file(remote + '/upload-owner.json'):
            unpublished()
            observed = io.BytesIO(); client.read(remote + '/upload-owner.json', observed.write, len(owner_raw))
            if observed.getvalue() != owner_raw: raise ValueError('Upload owner does not match journal')
            request = dict(schemaVersion='1.0.0', kind='PhotoBridgeRestoreRequest', sessionID=session,
                state='USB_VERIFIED', sourceManifestSHA256=digest, assetCount=len(manifest['assets']),
                resourceCount=len(resources), byteCount=total, photosImport='NOT_RUN')
            request_raw = json.dumps(request, indent=2).encode()
            entries = [(r['storedRelativePath'], r['byteCount'], r['sha256'], None) for r in resources]
            entries += [('album-order.json', len(raw), digest, raw),
                ('restore-request.json', len(request_raw), hashlib.sha256(request_raw).hexdigest(), request_raw)]
            prepared = []
            for relative, size, sha, data in entries:
                check_cancel(cancel_file)
                parts = relative.split('/'); parent = remote
                exists = True
                for component in parts[:-1]:
                    if component not in names(parent): exists = False; break
                    parent += '/' + component; regular(parent, True)
                contents = names(parent) if exists else set()
                name = parts[-1]; complete = name in contents; partial = name + '.part' in contents
                if complete and partial: raise ValueError('Ambiguous complete and partial files')
                offset = 0
                if complete:
                    if regular(remote + '/' + relative) != size: raise ValueError('Completed file size differs')
                    check(relative, None, size, sha)
                elif partial:
                    offset = regular(remote + '/' + relative + '.part')
                    if offset > size: raise ValueError('Partial is oversized')
                    source = io.BytesIO(data) if data is not None else regular_path(local, relative).open('rb')
                    with source:
                        if check(relative + '.part', source, size, sha, True) != offset: raise ValueError('Partial changed while checking')
                prepared.append((relative, size, sha, data, complete, partial, offset))
            if previous_journal is not None:
                write_json(journal, state, exclusive=True)
                journal_owned = True
            for relative, size, sha, data, complete, partial, offset in prepared:
                check_cancel(cancel_file)
                unpublished()
                if complete:
                    if data is None: state['reusedVerifiedResources'] += 1
                else:
                    parent = remote
                    for component in relative.split('/')[:-1]:
                        if component not in names(parent):
                            client.mkdir(parent + '/' + component, exclusive=True)
                            if parent in directory_names: directory_names[parent].add(component)
                        parent += '/' + component; regular(parent, True)
                    source = io.BytesIO(data) if data is not None else regular_path(local, relative).open('rb')
                    with source:
                        source.seek(offset)
                        if partial: client.append_existing(remote + '/' + relative + '.part', source, offset)
                        else: client.write_new(remote + '/' + relative + '.part', source)
                    if data is None:
                        state['resumedPartialBytes'] += offset; state['usbResourceBytesWritten'] += size - offset
                    check(relative + '.part', None, size, sha)
                    if data is not None:
                        # Revalidate the local backup before publishing metadata, especially the ready request.
                        revalidate_backup(local, raw, resources, digest, total, cancel_file=cancel_file)
                    unpublished(); client.commit_new(remote + '/' + relative + '.part', remote + '/' + relative)
                if data is None:
                    state['resourcesVerified'] += 1; state['bytesVerified'] += size
                state.update(snapshot(status='UPLOADING', started_monotonic=start, now_monotonic=time.monotonic(),
                    resources_verified=state['resourcesVerified'], total_resources=len(resources),
                    bytes_verified=state['bytesVerified'], total_bytes=total,
                    current_resource=resource_names.get(relative, '正在核对发送结果')))
                write_json(journal, state)
            state.update(state='USB_VERIFIED', status='USB_VERIFIED'); write_json(journal, state)
            return dict(state, journal=str(journal))
    except CancellationRequested as error:
        if journal_owned:
            state.update(state='STOPPED', status='STOPPED', error=str(error)); write_json(journal, state)
        raise
    except Exception as error:
        # A refused resume must not overwrite the previous journal or create a false ready request.
        if journal_owned:
            state.update(state='FAILED', status='FAILED', error=str(error)); write_json(journal, state)
        raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--local', type=Path, required=True); parser.add_argument('--resume-journal', type=Path)
    parser.add_argument('--cancel-file', type=Path)
    parser.add_argument('--journal-id', help='Uppercase UUID chosen by the Mac for direct progress reads')
    args = parser.parse_args(); client = AFC()
    try:
        client.vend('com.photobridge.OrderProbe')
        print(json.dumps(upload(client, args.local, args.resume_journal, args.cancel_file, args.journal_id), indent=2))
    except CancellationRequested as error:
        print(json.dumps({'state': 'STOPPED', 'error': str(error)})); sys.exit(3)
    finally: client.close()
