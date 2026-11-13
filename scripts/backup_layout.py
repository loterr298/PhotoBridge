"""Keep PhotoBridge's order metadata out of user-visible photo folders."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat

LEGACY_MARKER = '.photobridge-layout.json'
METADATA = {'album-order.json','source-order.json','transfer-progress.json','transfer-manifest.json',
            'filesystem-attributes.jsonl','resume-report.json'}
APP_SUPPORT = Path(os.environ.get(
    'PHOTOBRIDGE_LAYOUT_STORE',
    Path.home() / 'Library' / 'Application Support' / 'PhotoBridge' / 'FlatSessions'))

def _resolved(root):
    return str(Path(root).resolve())

def private_root(root):
    key = hashlib.sha256(_resolved(root).encode('utf-8')).hexdigest()[:32]
    return APP_SUPPORT / key

def _validate_private_layout(root, candidate):
    layout = candidate / 'layout.json'
    if candidate.is_symlink() or not candidate.is_dir() or layout.is_symlink() or not layout.is_file():
        return False
    if layout.stat().st_size > 4096: raise ValueError('Invalid private layout metadata')
    value = json.loads(layout.read_bytes())
    expected = {'kind': 'PhotoBridgeFlatAlbum', 'version': 2, 'userFolder': _resolved(root)}
    if value != expected: raise ValueError('Private layout belongs to a different folder')
    return True

def is_flat(root):
    root = Path(root)
    if root.is_symlink() or not root.is_dir(): return False
    private = private_root(root)
    if private.exists(): return _validate_private_layout(root, private)
    # Existing v1 folders are accepted read-only. New exports never create this marker.
    marker = root / LEGACY_MARKER
    if marker.is_symlink(): raise ValueError('Layout marker must not be a symbolic link')
    if not marker.exists(): return False
    if not marker.is_file() or marker.stat().st_size > 4096: raise ValueError('Invalid layout marker')
    value = json.loads(marker.read_bytes())
    if not isinstance(value, dict) or type(value.get('version')) is not int or value != {'kind':'PhotoBridgeFlatAlbum','version':1}:
        raise ValueError('Unsupported local album layout')
    return True

def storage_root(root):
    root = Path(root)
    if not is_flat(root): return root
    private = private_root(root)
    if private.exists() and _validate_private_layout(root, private): return private
    return root

def prepare_flat(root):
    root = Path(root)
    if root.is_symlink() or not root.is_dir(): raise ValueError('Flat export root must be a real directory')
    private = private_root(root)
    if private.exists(): raise FileExistsError(private)
    private.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    private.mkdir(mode=0o700, parents=False, exist_ok=False)
    (private / 'layout.json').write_text(json.dumps({'kind':'PhotoBridgeFlatAlbum','version':2,
        'userFolder':_resolved(root)}, ensure_ascii=False, sort_keys=True))
    (private / 'Resources').mkdir(mode=0o700)
    (private / 'asset-records').mkdir(mode=0o700)
    return private

def local_path(root, relative):
    root = Path(root)
    internal = storage_root(root)
    # Legacy v1 flat folders used hidden names. Keep them readable for resume.
    if internal == root and is_flat(root):
        if relative in METADATA: return root / ('.photobridge-' + relative)
        match = re.fullmatch(r'asset-records/([0-9]{6,})\.json', relative)
        if match: return root / f'.photobridge-asset-{match.group(1)}.json'
        if relative.startswith('Resources/'):
            match = re.fullmatch(r'Resources/([0-9]{6,})/([0-9]{4,})\.([A-Za-z0-9]{1,10})(\.part)?', relative)
            if match:
                ordinal, index, ext, part = match.groups()
                return root / f'.photobridge-resource-{ordinal}-{index}.{ext}{part or ""}'
    return internal / relative

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
    return storage_root(root) / 'restore-uploads' if is_flat(root) else Path(root)/'restore-uploads'

def upload_journal_name(root, identity):
    return identity + '.json'
