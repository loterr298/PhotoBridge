#!/usr/bin/env python3
"""Send exactly one ordered media file to the iPhone direct-import inbox."""
import argparse, hashlib, io, json, os, re
from pathlib import Path
from usb_probe import AFC

def safe_name(value):
    name = Path(value).name
    if not name or name in ('.', '..') or '/' in name or '\\' in name or '\x00' in name:
        raise ValueError('unsafe filename')
    return name

parser = argparse.ArgumentParser()
parser.add_argument('--local', type=Path, required=True)
parser.add_argument('--session', required=True)
parser.add_argument('--ordinal', type=int, required=True)
parser.add_argument('--bundle', default='com.photobridge.OrderProbe')
args = parser.parse_args()
if args.ordinal < 1 or not re.fullmatch(r'[0-9A-Fa-f-]{36}', args.session): raise ValueError('invalid direct session')
source = args.local
if source.is_symlink() or not source.is_file(): raise ValueError('source media must be a regular file')
name = safe_name(source.name)
digest = hashlib.sha256(); size = 0
with source.open('rb') as stream:
    while chunk := stream.read(1024 * 1024): digest.update(chunk); size += len(chunk)
client = AFC(); client.vend(args.bundle)
root = 'DirectInbox/' + args.session
try:
    try: client.mkdir('DirectInbox')
    except Exception: pass
    try: client.mkdir(root)
    except Exception: pass
    item = root + '/%06d' % args.ordinal
    try: client.mkdir(item)
    except Exception: pass
    part = item + '/' + name + '.part'
    final = item + '/' + name
    with source.open('rb') as stream: client.write_new(part, stream)
    client.commit_new(part, final)
    marker = json.dumps({'sessionID': args.session, 'ordinal': args.ordinal, 'filename': name,
                         'relativePath': final, 'byteCount': size, 'sha256': digest.hexdigest()}, sort_keys=True).encode()
    client.write_new(item + '/item.json', io.BytesIO(marker))
    print(json.dumps({'status': 'READY', 'sessionID': args.session, 'ordinal': args.ordinal,
                      'filename': name, 'relativePath': final, 'byteCount': size,
                      'sha256': digest.hexdigest()}))
finally:
    client.close()
