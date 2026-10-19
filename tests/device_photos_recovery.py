#!/usr/bin/env python3
"""Read-only audit of explicit-placeholder Photos restart evidence. Private IDs stay local."""
import argparse
import hashlib
import json
from pathlib import Path
import uuid
import stat
from device_staging_recovery import snapshot, read_json
from device_restore_audit import audit
from usb_probe import AFC


def bind_stop(manifest_raw, request_raw, plan_raw, progress, events, expected_build, session):
    manifest = json.loads(manifest_raw); plan = json.loads(plan_raw)
    sources = [a['sourceAssetLocalIdentifier'] for a in manifest['assets']]
    if (plan.get('schemaVersion') != '1.0.0' or plan.get('inboxSessionID') != session
            or plan.get('manifestSHA256') != hashlib.sha256(manifest_raw).hexdigest()
            or plan.get('requestSHA256') != hashlib.sha256(request_raw).hexdigest()
            or plan.get('sourceAlbumID') != manifest['sourceOrder']['albumIdentifier']
            or plan.get('sourceAssetIDs') != sources or not sources
            or plan.get('allowTimestampRewrite') is not False):
        raise ValueError('Stopped plan is not bound to this strict-policy source')
    uuid.UUID(plan['attemptID']); uuid.UUID(session)
    expected = {'album-intent.json': ('album-intent',0), 'album-placeholder.json': ('album-placeholder',0),
                '000001-intent.json': ('asset-intent',1), '000001-placeholder.json': ('asset-placeholder',1)}
    if set(events) != set(expected): raise ValueError('Expected exactly first unverified transaction ledger')
    for name,(kind,ordinal) in expected.items():
        e=events[name]
        if (e.get('schemaVersion')!='1.0.0' or e.get('attemptID')!=plan['attemptID']
                or e.get('planSHA256')!=hashlib.sha256(plan_raw).hexdigest()
                or e.get('kind')!=kind or e.get('ordinal')!=ordinal
                or e.get('sourceID')!=(sources[0] if ordinal else None) or e.get('modified') is not None):
            raise ValueError('Foreign or inconsistent durable event')
        if kind.endswith('intent') and e.get('createdID') is not None: raise ValueError('Invalid creation intent')
    album=events['album-placeholder.json'].get('createdID');first=events['000001-placeholder.json'].get('createdID')
    if (not isinstance(album,str) or not album or not isinstance(first,str) or not first or album==first
            or album in sources or first in sources or album==plan['sourceAlbumID'] or first==plan['sourceAlbumID']):
        raise ValueError('Invalid new-copy identities')
    required=dict(status='INCOMPLETE',runtimeBuild=expected_build,runtimeVersion='0.3.6',recoveryProtocol='explicit-placeholder-v1',
        diagnosticStopWindow='AFTER_FIRST_PHOTOS_COMMIT_BEFORE_RESOURCE_VERIFICATION',createdAssets=1,newAssetsCreatedThisRun=1,
        resourcesVerifiedAssets=0,recoveredExistingAssets=0,createdAlbumID=album,newAlbumTitle=plan['title'],
        attemptID=plan['attemptID'],userAuthorizedAdjustmentTimestampRewrite=False)
    if any(progress.get(k)!=v for k,v in required.items()): raise ValueError('Not the expected actual first-commit stop')
    return dict(firstCreatedID=first,albumID=album,sourceIDs=sources,attemptID=plan['attemptID'],runtimeBuild=expected_build,
                verificationDirectory=progress.get('verificationDirectory'),title=plan['title'],sourceAlbumID=plan['sourceAlbumID'])


def bind_final(report, baseline):
    sources=baseline['sourceIDs'];ids=report.get('observedCreatedAssetIDs',[])
    required=dict(runtimeBuild=baseline['runtimeBuild'],recoveryProtocol='explicit-placeholder-v1',recoveryInvocation=True,
        attemptID=baseline['attemptID'],createdAlbumID=baseline['albumID'],newAlbumTitle=baseline['title'],createdAssets=len(sources),resourcesVerifiedAssets=len(sources),
        newAssetsCreatedThisRun=len(sources)-1,recoveredExistingAssets=1,userAuthorizedAdjustmentTimestampRewrite=False)
    if (any(report.get(k)!=v for k,v in required.items()) or len(ids)!=len(sources) or not ids
            or not all(isinstance(i,str) and i for i in ids)
            or ids[0]!=baseline['firstCreatedID'] or len(set(ids))!=len(ids)
            or set(ids).intersection(baseline['sourceIDs']+[baseline['sourceAlbumID'],baseline['albumID']])
            or report.get('sourceToCreatedAssetIDs')!=dict(zip(sources,ids))
            or report.get('verificationDirectory')==baseline.get('verificationDirectory')):
        raise ValueError('Final recovery does not preserve original identity or remaining-copy accounting')


def validate_saved_state(baseline_directory):
    root=Path(baseline_directory);files=root/'phone-files'
    if files.is_symlink() or not files.is_dir(): raise ValueError('Invalid saved baseline directory')
    state=json.loads((root/'phone-state.json').read_bytes());actual={}
    for path in files.rglob('*'):
        if path.is_symlink(): raise ValueError('Saved baseline symlink')
        if path.is_dir(): continue
        info=path.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1: raise ValueError('Invalid saved baseline file')
        digest=hashlib.sha256();count=0
        with path.open('rb') as stream:
            for data in iter(lambda:stream.read(1024*1024),b''):digest.update(data);count+=len(data)
        actual[path.relative_to(files).as_posix()]=(digest.hexdigest(),count)
    required={'album-order.json','restore-request.json','restore-started.json','restore-progress.json','restore-recovery/plan.json',
              'restore-recovery/album-intent.json','restore-recovery/album-placeholder.json',
              'restore-recovery/000001-intent.json','restore-recovery/000001-placeholder.json'}
    if not isinstance(state,dict) or not required.issubset(state) or set(state)!=set(actual):
        raise ValueError('Saved baseline state is empty or incomplete')
    for name,(digest,count) in actual.items():
        value=state[name]
        if not isinstance(value,dict):raise ValueError('Invalid baseline record')
        attributes=value.get('attributes')
        if (value.get('sha256')!=digest or value.get('byteCount')!=count or not isinstance(attributes,dict)
                or attributes.get('st_size')!=str(count) or attributes.get('st_nlink')!='1'
                or not isinstance(attributes.get('st_mtime'),str)):
            raise ValueError('Saved baseline bytes or attribute record differs')
    return state


def stopped_binding(output):
    files=Path(output)/'phone-files';directory=files/'restore-recovery'
    events={p.name:json.loads(p.read_bytes()) for p in directory.iterdir() if p.name!='plan.json'}
    request=json.loads((Path(output)/'private-request.json').read_bytes())
    return bind_stop((files/'album-order.json').read_bytes(),(files/'restore-request.json').read_bytes(),
        (directory/'plan.json').read_bytes(),json.loads((files/'restore-progress.json').read_bytes()),events,
        request['expectedBuild'],request['remote'].split('/')[-1])


def verify(client, baseline_directory, source, output, relaunch_confirmed=False):
    if not relaunch_confirmed: raise ValueError('User App relaunch attestation required for this scoped audit')
    baseline_directory=Path(baseline_directory);output=Path(output)
    baseline=stopped_binding(baseline_directory)
    request=json.loads((baseline_directory/'private-request.json').read_bytes());remote=request['remote']
    segments=remote.split('/')
    if (len(segments)!=2 or segments[0]!='RestoreInbox'
            or str(uuid.UUID(segments[1]))!=segments[1].lower()): raise ValueError('Unsafe restore inbox path')
    old=validate_saved_state(baseline_directory)
    def unchanged():
        current=snapshot(client,remote)
        # Latest progress is the sole explicitly mutable old file; all earlier run files and ledgers stay immutable.
        if any(current.get(name)!=value for name,value in old.items() if name!='restore-progress.json'):
            raise ValueError('Preserved pre-restart phone file bytes/available attributes changed')
    unchanged()
    result=audit(client,remote,source,output)
    # Bind exactly the report whose resources audit() downloaded and checked, never a separate earlier fetch.
    report=json.loads((output/'restore-report.json').read_bytes());bind_final(report,baseline)
    unchanged()
    result.update(status='PHOTOS_POST_COMMIT_RELAUNCH_RECOVERY_VERIFIED',sameFirstCreatedID=True,sameCreatedAlbum=True,
        recoveredExistingAssets=1,newAssetsCreatedThisRun=len(baseline['sourceIDs'])-1,
        oldPhoneFilesBytesAndAvailableAttributesUnchanged=True,preservedOldFiles=len(old)-1,
        latestProgressMirrorExcluded=True,userConfirmedAppRelaunch=relaunch_confirmed,
        countersEvidence='App runtime report; first identity, immutable files and full output bytes independently checked',
        forcedTerminationDuringPhotosCommit='NOT_RUN',manualLivePlayback='NOT_RUN',manualPhotosOrder='NOT_RUN')
    (output/'recovery-audit.json').write_text(json.dumps(result,indent=2)+'\n')
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--baseline',type=Path,required=True)
    p.add_argument('--source',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--relaunch-confirmed',action='store_true');a=p.parse_args()
    c=AFC()
    try:
        c.vend('com.photobridge.OrderProbe')
        print(json.dumps(verify(c,a.baseline,a.source,a.output,a.relaunch_confirmed),indent=2))
    finally:c.close()
