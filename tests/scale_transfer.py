#!/usr/bin/env python3
"""Synthetic AFC boundary + real flat local files. Never accesses a device or Photos.
Run: python3 tests/scale_transfer.py --assets 50000 --report build/scale-transfer.json
"""
import argparse
import contextlib
import hashlib
import io
import json
from pathlib import Path
import resource
import sys
import tempfile
import time
import uuid
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from album_export import download_live_album, validate_manifest
from backup_layout import visible_name
from album_restore import validated_backup
from upload_resume import upload


def payload(ordinal, index):
    return (f'SYNTHETIC-NOT-A-PHOTO:{ordinal:06d}:{index}:'.encode() * 40)[:1024]


def fixture(count):
    assets = []; members = []
    for i in range(1, count + 1):
        roles = [(1, 'HEIC', 'public.heic')]
        if i % 4 == 0: roles.append((9, 'MOV', 'com.apple.quicktime-movie'))
        if i % 5 == 0: roles += [(5, 'JPEG', 'public.jpeg'), (7, 'AAE', 'com.apple.property-list')]
        resources = []
        for index, (role, ext, uti) in enumerate(roles, 1):
            data = payload(i, index)
            resources.append(dict(resourceIndex=index, resourceType=role, originalFilename='same.' + ext,
                uniformTypeIdentifier=uti, storedRelativePath=f'Resources/{i:06d}/{index:04d}.{ext}',
                sha256=hashlib.sha256(data).hexdigest(), byteCount=len(data)))
        identifier = f'source-{count-i:06d}'  # Names/IDs deliberately oppose album order.
        members.append(dict(ordinal=i, localIdentifier=identifier))
        assets.append(dict(ordinal=i, resourceGroupId=str(uuid.UUID(int=i)), sourceAssetLocalIdentifier=identifier,
            pixelWidth=4032, pixelHeight=3024, mediaType=1, mediaSubtypes=8 if i % 4 == 0 else 0, resources=resources))
    m = dict(schemaVersion='1.0.0',kind='PhotoBridgeOriginalExport',sessionID=str(uuid.uuid4()).upper(),status='staged',intervalSeconds=5,
        timestampScope='new-Mac-copies-filesystem-only',restorationStatus='NOT_RUN',assets=assets,
        sourceOrder=dict(schemaVersion='1.0.0',albumName='SYNTHETIC',albumIdentifier='synthetic-album',authorization='full',fetchMode='nil-options',
            capturedAt='2026-10-25T00:00:00Z',systemVersion='synthetic',build='scale-test',verification='NOT_RUN',members=members))
    validate_manifest(m); return m


class Source:
    def __init__(self, manifest):
        self.m=manifest; self.raw=json.dumps(manifest,separators=(',',':')).encode(); self.status_reads=0; self.reconnects=0
        count=len(manifest['assets']); self.failures={max(1,count//10),max(1,count//2),max(1,count*9//10)}
    def reconnect(self): self.reconnects+=1
    def read(self,path,sink,maximum=None):
        if path.startswith('Control/Jobs/'):
            self.status_reads+=1
            data=json.dumps(dict(requestID=REQUEST,albumIdentifier='synthetic-album',sessionID=self.m['sessionID'],status='STAGED')).encode()
        elif path.endswith('/source-order.json'):data=json.dumps(self.m['sourceOrder']).encode()
        elif '/asset-records/' in path:
            ordinal=int(Path(path).stem)
            if ordinal % 5000 == 0: print(f'SYNTHETIC export {ordinal}/{len(self.m["assets"])}',flush=True)
            data=json.dumps(self.m['assets'][ordinal-1]).encode()
        elif path.endswith('/album-order.json'):data=self.raw
        else:
            parts=path.split('/');ordinal=int(parts[-2]);index=int(Path(parts[-1]).stem);data=payload(ordinal,index)
            if ordinal in self.failures:
                self.failures.remove(ordinal);sink(data[:13]);raise RuntimeError('AFC read: error 30')
        if maximum is not None and len(data)>maximum:raise ValueError('Test manifest exceeds production size bound')
        for offset in range(0,len(data),1024*1024):sink(data[offset:offset+1024*1024])


class Inbox:
    def __init__(self):self.files={};self.dirs={''};self.fail=False;self.partial_offset=None
    def mkdir(self,path,exclusive=False):
        if exclusive and (path in self.dirs or path in self.files):raise FileExistsError(path)
        self.dirs.add(path)
    def list(self,path):
        # Only direct children; maintain the real AFC directory semantics.
        return list(self.children.get(path,()))
    @property
    def children(self):
        return self._children
    def _add(self,path):
        parent,name=path.rsplit('/',1);self._children.setdefault(parent,set()).add(name)
    def info(self,path):
        if path in self.dirs:return dict(st_ifmt='S_IFDIR',st_size='0',st_nlink='1')
        return dict(st_ifmt='S_IFREG',st_size=str(len(self.files[path])),st_nlink='1')
    @contextlib.contextmanager
    def locked_file(self,path):yield
    def read(self,path,sink,maximum=None):
        data=self.files[path]
        if maximum is not None and len(data)>maximum:raise ValueError('Read bound')
        sink(data)
    def write_new(self,path,source):
        if path in self.files:raise FileExistsError(path)
        data=source.read();self.files[path]=data;self._add(path)
        if '/Resources/' in path and int(path.split('/')[-2]) % 10000 == 0:
            print('SYNTHETIC upload '+path.split('/')[-2],flush=True)
        if self.fail and '/Resources/' in path and int(path.split('/')[-2])>=self.cut:
            self.files[path]=data[:17];self.fail=False;raise RuntimeError('SYNTHETIC_UPLOAD_CUT')
    def append_existing(self,path,source,offset):
        assert len(self.files[path])==offset;self.partial_offset=offset;self.files[path]+=source.read()
    def commit_new(self,part,final):
        if final in self.files:raise FileExistsError(final)
        self.files[final]=self.files.pop(part);parent,name=part.rsplit('/',1);self._children[parent].remove(name);self._add(final)


REQUEST=str(uuid.uuid4())
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--assets',type=int,default=1000);parser.add_argument('--report',type=Path,required=True);args=parser.parse_args()
    assert 20<=args.assets<=50000
    manifest=fixture(args.assets);source=Source(manifest);started=time.monotonic()
    with tempfile.TemporaryDirectory(prefix='photobridge-synthetic-') as temp:
        local=Path(temp)/'album'
        result=download_live_album(source,REQUEST,'synthetic-album',local,flat=True)
        download_seconds=time.monotonic()-started
        raw,observed,resources,digest,total=validated_backup(local)
        visible=sorted(p.name for p in local.iterdir() if not p.name.startswith('.'))
        expected_names=[]; used={}
        for asset in manifest['assets']:
            base=visible_name(asset); used[base]=used.get(base,0)+1
            if used[base] == 1: expected_names.append(base)
            else:
                stem,suffix=Path(base).stem,Path(base).suffix
                expected_names.append(f'{stem} ({used[base]}){suffix}')
        assert len(visible)==args.assets and set(visible)==set(expected_names)
        assert not any(p.is_dir() for p in local.iterdir())
        assert [a['sourceAssetLocalIdentifier'] for a in observed['assets']]==[m['localIdentifier'] for m in observed['sourceOrder']['members']]
        inbox=Inbox();inbox._children={}
        original_mkdir=inbox.mkdir
        def mkdir(path,exclusive=False):original_mkdir(path,exclusive);inbox._add(path) if '/' in path else None
        inbox.mkdir=mkdir;inbox.fail=True;inbox.cut=args.assets//2
        upload_start=time.monotonic()
        try:upload(inbox,local)
        except RuntimeError as e:assert str(e)=='SYNTHETIC_UPLOAD_CUT'
        else:raise AssertionError('Expected interruption')
        journal=list(local.glob('.photobridge-upload-*.json'));assert len(journal)==1
        assert not any(p.endswith('/restore-request.json') for p in inbox.files)
        prior=journal[0].read_bytes();finished=upload(inbox,local,journal[0]);assert journal[0].read_bytes()==prior
        assert finished['state']=='USB_VERIFIED' and inbox.partial_offset==17
        remote=finished['remote'];assert inbox.files[remote+'/album-order.json']==raw
        for r in resources:
            data=inbox.files[remote+'/'+r['storedRelativePath']]
            assert len(data)==r['byteCount'] and hashlib.sha256(data).hexdigest()==r['sha256']
        assert not any(p.is_dir() for p in local.iterdir())
        report=dict(synthetic=True,assets=args.assets,resources=len(resources),bytes=total,manifestBytes=len(raw),
            export='PASS real local flat files; all resource hashes verified',upload='PASS synthetic AFC readback; all hashes and canonical manifest bytes equal',
            order='PASS canonical manifest source identifiers/ordinals; visible names preserve original basenames with deterministic duplicate suffixes',childDirectories=0,
            injectedExportServiceInterruptions=source.reconnects,injectedUploadInterruption='PASS partial offset 17; previous journal unchanged; request unpublished until verified',
            downloadSeconds=download_seconds,uploadIncludingResumeSeconds=time.monotonic()-upload_start,statusPolls=source.status_reads,
            peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * (1 if sys.platform=='darwin' else 1024),photosImport='NOT_RUN',realUSBThroughput='NOT_MEASURED')
    args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
