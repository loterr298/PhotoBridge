#!/usr/bin/env python3
"""Small USB-only control channel for the Mac-first PhotoBridge workflow.

The command files live in the iPhone app's shared Documents directory. Files
are written as ``.part`` and renamed atomically through AFC, so the iPhone
never reads a half-written request. This channel carries only commands and
status JSON; photo bytes continue through the existing album exporter.
"""
import argparse
import io
import json
import sys
import uuid
import time

from usb_probe import AFC


def ensure_directory(client, path):
    parts = []
    for part in path.split('/'):
        parts.append(part)
        try:
            client.mkdir('/'.join(parts))
        except Exception as error:
            # mkdir is idempotent in AFC, but older libimobiledevice builds
            # report a generic error for an existing directory. Confirm it is
            # really present before surfacing the failure.
            if part not in client.list('/'.join(parts[:-1]) or '.'):
                raise error


def send(client, request_id, payload):
    if str(uuid.UUID(request_id)).lower() != request_id.lower() or payload.get('id') != request_id:
        raise ValueError('Invalid request identity')
    payload = dict(payload, expiresAt=time.time() + 300)
    ensure_directory(client, 'Control')
    ensure_directory(client, 'Control/Requests')
    path = f'Control/Requests/{request_id}.json'
    temporary = path + '.part'
    data = json.dumps(payload, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    client.write_new(temporary, io.BytesIO(data))
    client.commit_new(temporary, path)
    return {'status': 'SENT', 'requestID': request_id}


def read(client, path):
    raw = io.BytesIO()
    client.read(path, raw.write, 1024 * 1024)
    # Keep stdout JSON-only so the Swift client can parse it directly.
    value = json.loads(raw.getvalue().decode('utf-8'))
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['send', 'read'])
    parser.add_argument('--bundle', default='com.photobridge.OrderProbe')
    parser.add_argument('--request-id')
    parser.add_argument('--payload-file')
    parser.add_argument('--path')
    args = parser.parse_args()
    client = None
    try:
        client = AFC()
        client.vend(args.bundle)
        if args.command == 'send':
            if not args.request_id or not args.payload_file:
                raise ValueError('--request-id and --payload-file are required')
            with open(args.payload_file, 'rb') as source:
                payload = json.load(source)
            result = send(client, args.request_id, payload)
        else:
            if not args.path or args.path.startswith('/') or '..' in args.path.split('/'):
                raise ValueError('--path must be a relative Documents path')
            result = read(client, args.path)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except Exception as error:
        print(json.dumps({'status': 'FAILED', 'error': str(error)}, ensure_ascii=False))
        return 2
    finally:
        if client:
            client.close()


if __name__ == '__main__':
    sys.exit(main())
