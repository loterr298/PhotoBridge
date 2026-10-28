"""Mac-only flat presentation; the authoritative iPhone manifest stays unchanged."""
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat

MARKER = '.photobridge-layout.json'
METADATA = {'album-order.json','source-order.json','transfer-progress.json','transfer-manifest.json',
            'filesystem-attributes.jsonl','resume-report.json'}

def is_flat(root):
    marker = Path(root) / MARKER
    if marker.is_symlink(): raise ValueError('Layout marker must not be a symbolic link')
    if not marker.exists(): return False
    if not marker.is_file() or marker.stat().st_size > 4096: raise ValueError('Invalid layout marker')
    value = json.loads(marker.read_bytes())
    if not isinstance(value, dict) or type(value.get('version')) is not int or value != {'kind':'PhotoBridgeFlatAlbum','version':1}:
        raise ValueError('Unsupported local album layout')
    return True

def prepare_flat(root):
    with (Path(root)/MARKER).open('x') as f: json.dump({'kind':'PhotoBridgeFlatAlbum','version':1},f)

def local_path(root, relative):
    root = Path(root)
    if is_flat(root):
        match = re.fullmatch(r'Resources/([0-9]{6,})/([0-9]{4,})\.([A-Za-z0-9]{1,10})(\.part)?', relative)
        if match:
            ordinal,index,ext,part = match.groups()
            return root / f'.photobridge-resource-{ordinal}-{index}.{ext}{part or ""}'
        match = re.fullmatch(r'asset-records/([0-9]{6,})\.json', relative)
        if match: return root / f'.photobridge-asset-{match.group(1)}.json'
        if relative in METADATA: return root / ('.photobridge-' + relative)
    return root / relative

def primary_resource(asset):
    preferred = (6,2) if asset['mediaType'] == 2 else (5,1,4)
    return next((r for kind in preferred for r in asset['resources'] if r['resourceType']==kind),asset['resources'][0])

def visible_name(asset):
    resource = primary_resource(asset)
    original = PurePosixPath(resource['originalFilename']).name
    safe = ''.join('-' if c in '/\\:' or ord(c) < 32 else c for c in original).strip(' .')
    return safe or '照片'

def publish_photo(root, asset):
    if not is_flat(root): return
    source = local_path(root,primary_resource(asset)['storedRelativePath'])
    if not stat.S_ISREG(source.lstat().st_mode): raise ValueError('Photo must be a regular verified file')
    destination = Path(root)/visible_name(asset)
    if destination.exists() or destination.is_symlink():
        stem, suffix = destination.stem, destination.suffix
        index = 2
        while (Path(root) / f'{stem} ({index}){suffix}').exists(): index += 1
        destination = Path(root) / f'{stem} ({index}){suffix}'
    os.link(source,destination,follow_symlinks=False)  # Exclusive; no extra media bytes or re-encoding.
    if not stat.S_ISREG(destination.lstat().st_mode): raise ValueError('Invalid visible photo link')

def upload_journals(root):
    return Path(root) if is_flat(root) else Path(root)/'restore-uploads'

def upload_journal_name(root, identity):
    return ('.photobridge-upload-' if is_flat(root) else '') + identity + '.json'
