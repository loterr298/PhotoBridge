#!/usr/bin/env python3
"""Read-only USB audit of one-resource stop/relaunch/new-session staging recovery. Private output only."""
import argparse
import copy
import datetime
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from album_export import download_album, session_path
from album_restore import validated_backup
from usb_probe import AFC


def read_json(client, path):
    data = bytearray(); client.read(path, data.extend, 64 * 1024 * 1024)
    return bytes(data), json.loads(data)


def exchange_date(value):
    # The internal plan uses Date's reference epoch and exact fractions;
    # JSONEncoder.iso8601 writes whole UTC seconds in the exchange manifest.
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError('Invalid internal source date')
    return datetime.datetime.fromtimestamp(math.floor(value) + 978307200, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def bind_plan_manifest(plan, manifest):
    expected_order = copy.deepcopy(plan['sourceOrder'])
    expected_order['capturedAt'] = exchange_date(expected_order['capturedAt'])
    for member in expected_order['members']:
        if member.get('creationDate') is not None: member['creationDate'] = exchange_date(member['creationDate'])
    if (manifest['sessionID'] != plan['sessionID'] or manifest['sourceOrder'] != expected_order
            or len(manifest['assets']) != len(plan['assets'])):
        raise ValueError('Final manifest is not bound to session and complete frozen source order')
    for ordinal, (asset, source) in enumerate(zip(manifest['assets'], plan['assets']), 1):
        expected_date = exchange_date(source['creationDate']) if source.get('creationDate') is not None else None
        if (asset['ordinal'] != ordinal or asset['sourceAssetLocalIdentifier'] != source['identifier']
                or asset.get('originalPhotoLibraryCreationDate') != expected_date
                or any(asset[k] != source[k] for k in ['pixelWidth','pixelHeight','mediaType','mediaSubtypes'])
                or len(asset['resources']) != len(source['resources'])):
            raise ValueError('Final asset is not bound to frozen source metadata')
        for index, (resource, descriptor) in enumerate(zip(asset['resources'], source['resources']), 1):
            if resource['resourceIndex'] != index or any(resource[k] != descriptor[k] for k in ['resourceType','originalFilename','uniformTypeIdentifier']):
                raise ValueError('Final resource catalog is not bound to frozen source')


def snapshot(client, remote, destination=None):
    result = {}; stack = [(remote, '')]
    while stack:
        directory, relative = stack.pop()
        if len(relative.split('/')) > 32: raise ValueError('Unexpected staging depth')
        if client.info(directory).get('st_ifmt') != 'S_IFDIR': raise ValueError('Non-directory ancestor')
        for name in client.list(directory):
            if name in ('', '.', '..') or any(c in name for c in ['/', '\\', '\0']): raise ValueError('Unsafe phone filename')
            path = directory + '/' + name; local = (relative + '/' + name).lstrip('/'); info = client.info(path)
            if info.get('st_ifmt') == 'S_IFDIR': stack.append((path, local)); continue
            if info.get('st_ifmt') != 'S_IFREG' or info.get('st_nlink') != '1' or 'st_mtime' not in info:
                raise ValueError('Cannot safely audit phone file/mtime')
            count = 0; digest = hashlib.sha256(); stream = None
            if destination is not None:
                target = destination / local; target.parent.mkdir(parents=True, exist_ok=True); stream = target.open('xb')
            def receive(data):
                nonlocal count
                count += len(data); digest.update(data)
                if stream is not None: stream.write(data)
            try: client.read(path, receive, int(info['st_size']))
            finally:
                if stream is not None: stream.close()
            if count != int(info['st_size']): raise ValueError('Phone snapshot size changed')
            result[local] = dict(sha256=digest.hexdigest(), byteCount=count,
                attributes={k: info[k] for k in ['st_size', 'st_mtime', 'st_birthtime', 'st_nlink'] if k in info})
    return result


def capture(client, remote, output, expected_build):
    remote = session_path(remote); output = Path(output)
    if 'album-order.json' in client.list(remote): raise ValueError('Source is already staged')
    raw, plan = read_json(client, remote + '/staging-plan.json')
    _, progress = read_json(client, remote + '/export-progress.json')
    if (plan['sessionID'] != remote.split('/')[-1] or progress['status'] != 'STOPPED'
            or progress['resourcesCompleted'] != 1 or progress['runningBuild'] != expected_build):
        raise ValueError('Expected actual target build stopped after exactly one complete resource')
    output.mkdir(mode=0o700, exist_ok=False)
    state = snapshot(client, remote, output / 'preserved-source')
    records = [p for p in state if p.startswith('resource-records/') and p.endswith('.json')]
    if len(records) != 1: raise ValueError('Expected exactly one resource checkpoint')
    checkpoint = json.loads((output / 'preserved-source' / records[0]).read_bytes())
    r = checkpoint['resource']
    if (checkpoint['sessionID'] != plan['sessionID'] or checkpoint['planSHA256'] != hashlib.sha256(raw).hexdigest()
            or state[r['storedRelativePath']]['sha256'] != r['sha256'] or state[r['storedRelativePath']]['byteCount'] != r['byteCount']):
        raise ValueError('Stopped checkpoint does not bind actual cached bytes')
    if snapshot(client, remote) != state: raise ValueError('Stopped source still changing')
    (output / 'source-state.json').write_text(json.dumps(state, indent=2))
    (output / 'private-request.json').write_text(json.dumps(dict(remote=remote, expectedBuild=expected_build), indent=2))
    return dict(status='STOPPED_SOURCE_BASELINE_CAPTURED',completeResources=1,phoneFilesWritten=False,
        deviceStagingRecovery='NOT_RUN',phoneBirthtimeAvailable=all('st_birthtime' in v['attributes'] for v in state.values()))


def verify(client, remote, output, reference, relaunch_confirmed=False):
    remote = session_path(remote); output = Path(output)
    request = json.loads((output / 'private-request.json').read_bytes()); old = request['remote']
    state = json.loads((output / 'source-state.json').read_bytes())
    if remote == old or snapshot(client, old) != state: raise ValueError('Old source changed or session reused')
    old_raw = (output / 'preserved-source/staging-plan.json').read_bytes(); old_plan = json.loads(old_raw)
    _, plan = read_json(client, remote + '/staging-plan.json'); _, progress = read_json(client, remote + '/export-progress.json')
    if (plan['sessionID'] != remote.split('/')[-1] or plan['sourceOrder'] != old_plan['sourceOrder'] or plan['assets'] != old_plan['assets']
            or progress['status'] != 'STAGED' or progress['runningBuild'] != request['expectedBuild']
            or progress['resumedFromSession'] != old_plan['sessionID'] or progress['previousPlanSHA256'] != hashlib.sha256(old_raw).hexdigest()
            or progress['reusedVerifiedResources'] != 1 or progress['partialResourceBytesReused'] != 0):
        raise ValueError('Recovery plan, build or reuse accounting mismatch')
    _, expected, expected_resources, _, expected_total = validated_backup(Path(reference))
    result = download_album(client, remote, output / 'completed-backup')
    manifest = json.loads((output / 'completed-backup/album-order.json').read_bytes())
    bind_plan_manifest(plan, manifest)
    if any(manifest['sourceOrder'][k] != expected['sourceOrder'][k] for k in ['albumIdentifier', 'albumName', 'members']):
        raise ValueError('Reference source membership/order/creation metadata differs')
    def resources(m): return [{k: a[k] for k in ['ordinal', 'sourceAssetLocalIdentifier', 'originalPhotoLibraryCreationDate',
        'pixelWidth', 'pixelHeight', 'mediaType', 'mediaSubtypes', 'resources'] if k in a} for a in m['assets']]
    if resources(manifest) != resources(expected): raise ValueError('Actual resources/metadata differ from preserved full reference')
    for r in expected_resources:
        path = output / 'completed-backup' / r['storedRelativePath']
        sha = subprocess.check_output(['/usr/bin/shasum', '-a', '256', str(path)], text=True).split()[0]
        if sha != r['sha256'] or path.stat().st_size != r['byteCount']: raise ValueError('Independent shasum mismatch')
    if (progress['resourcesCompleted'] != len(expected_resources) or progress['bytesCompleted'] != expected_total
            or progress['photoKitResourcesRead'] != len(expected_resources) - 1 or snapshot(client, old) != state):
        raise ValueError('Final accounting or preserved old state differs')
    summary = dict(status='IOS_STAGING_RESOURCE_BOUNDARY_RECOVERY_VERIFIED',resourcesVerified=len(expected_resources),
        bytesVerified=expected_total,reusedVerifiedResources=1,photoKitResourcesRead=progress['photoKitResourcesRead'],
        partialResourceBytesReused=0,independentMacShasumMatches=len(expected_resources),newSession=True,
        oldPhoneFilesBytesAndAvailableAttributesUnchanged=True,
        phoneBirthtimeAvailable=all('st_birthtime' in v['attributes'] for v in state.values()),
        userConfirmedAppRelaunch=relaunch_confirmed,phoneFilesWrittenByAudit=False,photosImport='NOT_RUN',
        forcedTerminationDuringResourceWrite='NOT_RUN',sourceReferenceByteIdentity=True,downloadStatus=result['status'],
        runtimeBuild=progress['runningBuild'],counterEvidence='App runtime journal; output bytes independently verified',
        frozenSourceAndFinalManifestBound=True,oldPhoneDirectoryAttributes='NOT_AUDITED')
    with (output / 'summary.json').open('x') as f: json.dump(summary, f, indent=2)
    return summary


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__); p.add_argument('action', choices=['capture', 'verify'])
    p.add_argument('--remote', required=True); p.add_argument('--output', type=Path, required=True)
    p.add_argument('--expected-build'); p.add_argument('--reference', type=Path); p.add_argument('--relaunch-confirmed', action='store_true')
    a = p.parse_args()
    if a.action == 'capture' and not a.expected_build: p.error('capture requires --expected-build')
    if a.action == 'verify' and not a.reference: p.error('verify requires --reference preserved complete backup')
    c = AFC()
    try:
        c.vend('com.photobridge.OrderProbe')
        print(json.dumps(capture(c, a.remote, a.output, a.expected_build) if a.action == 'capture'
            else verify(c, a.remote, a.output, a.reference, a.relaunch_confirmed), indent=2))
    finally: c.close()
