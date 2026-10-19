#!/usr/bin/env python3
"""M0 USB-only House Arrest/AFC synthetic file probe. No photo library access.
Dynamically uses a separately installed libimobiledevice (LGPL-2.1-or-later).
Never bundles a library, deletes user files, or modifies original media.
"""
import argparse
import ctypes as C
import ctypes.util
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
import uuid

CHUNK = 1024 * 1024
SIZE = 100 * CHUNK


def documents_path(value):
    """VendDocuments exposes the app container with access restricted to /Documents."""
    if value == '.': return '/Documents'
    if not value or value.startswith('/') or '\\' in value or '\x00' in value:
        raise ValueError('Expected a relative Documents path')
    if any(part in ('', '.', '..') for part in value.split('/')):
        raise ValueError('Documents path traversal or ambiguous component')
    return '/Documents/' + value


def probe_directory(value):
    parts = value.split('/')
    if len(parts) != 3 or parts[:2] not in [['USBProbe', 'Outbox'], ['USBProbe', 'Inbox']]:
        raise ValueError('Only USBProbe/Outbox/<UUID> or USBProbe/Inbox/<UUID> is allowed')
    if str(uuid.UUID(parts[2])) != parts[2].lower():
        raise ValueError('Invalid UUID')
    return value


def validate_receipt(value, origin):
    if (value.get('filename') != 'probe.bin' or value.get('origin') != origin
            or not isinstance(value.get('byteCount'), int) or value['byteCount'] < SIZE
            or not re.fullmatch('[a-f0-9]{64}', value.get('sha256', ''))):
        raise ValueError('Invalid receipt / origin / filename / hash / size (<100 MiB)')


def inspect(path):
    h = hashlib.sha256(); count = 0
    with open(path, 'rb') as f:
        while True:
            data = f.read(CHUNK)
            if not data: break
            h.update(data); count += len(data)
    return {'filename': 'probe.bin', 'sha256': h.hexdigest(), 'byteCount': count}


def generate(path, size=SIZE):
    h = hashlib.sha256(); remaining = size
    with open(path, 'xb') as f:
        while remaining:
            data = os.urandom(min(CHUNK, remaining)); f.write(data); h.update(data); remaining -= len(data)
        f.flush(); os.fsync(f.fileno())
    return {'filename': 'probe.bin', 'sha256': h.hexdigest(), 'byteCount': size, 'origin': 'Mac'}


def write_all(writer, data):
    offset = 0
    while offset < len(data):
        count = writer(data[offset:])
        if count <= 0 or count > len(data) - offset: raise IOError('AFC write stalled or returned invalid count')
        offset += count


def load_library(label, names, fallbacks):
    errors = []
    candidates = [ctypes.util.find_library(name) for name in names] + fallbacks
    for path in dict.fromkeys(path for path in candidates if path):
        try: return C.CDLL(path)
        except OSError as error: errors.append(str(error))
    raise RuntimeError(label + ' unavailable. Install a compatible libimobiledevice/libplist: ' + '; '.join(errors))


class AFC:
    def __init__(self, udid=None):
        self.device = C.c_void_p(); self.house = C.c_void_p(); self.afc = C.c_void_p()
        self.lib = load_library('imobiledevice', ['imobiledevice-1.0', 'imobiledevice'], ['/usr/local/lib/libimobiledevice-1.0.6.dylib', '/usr/local/lib/libimobiledevice.dylib'])
        self.plist = load_library('plist', ['plist-2.0', 'plist'], ['/usr/local/lib/libplist-2.0.3.dylib'])
        ptr = C.c_void_p; u64 = C.c_uint64; u32 = C.c_uint32
        signatures = {
            'idevice_new_with_options': ([C.POINTER(ptr), C.c_char_p, C.c_int], C.c_int),
            'idevice_free': ([ptr], C.c_int),
            'house_arrest_client_start_service': ([ptr, C.POINTER(ptr), C.c_char_p], C.c_int),
            'house_arrest_send_command': ([ptr, C.c_char_p, C.c_char_p], C.c_int),
            'house_arrest_get_result': ([ptr, C.POINTER(ptr)], C.c_int),
            'afc_client_new_from_house_arrest_client': ([ptr, C.POINTER(ptr)], C.c_int),
            'afc_file_open': ([ptr, C.c_char_p, C.c_int, C.POINTER(u64)], C.c_int),
            'afc_file_close': ([ptr, u64], C.c_int),
            'afc_file_read': ([ptr, u64, ptr, u32, C.POINTER(u32)], C.c_int),
            'afc_file_seek': ([ptr, u64, C.c_int64, C.c_int], C.c_int),
            'afc_file_write': ([ptr, u64, ptr, u32, C.POINTER(u32)], C.c_int),
            'afc_make_directory': ([ptr, C.c_char_p], C.c_int),
            'afc_rename_path': ([ptr, C.c_char_p, C.c_char_p], C.c_int),
            'afc_read_directory': ([ptr, C.c_char_p, C.POINTER(C.POINTER(C.c_char_p))], C.c_int),
            'afc_dictionary_free': ([C.POINTER(C.c_char_p)], C.c_int),
            'afc_client_free': ([ptr], C.c_int),
            'house_arrest_client_free': ([ptr], C.c_int),
        }
        for name, (args, result) in signatures.items():
            fn = getattr(self.lib, name); fn.argtypes = args; fn.restype = result
        self.plist.plist_dict_get_item.argtypes = [ptr, C.c_char_p]; self.plist.plist_dict_get_item.restype = ptr
        self.plist.plist_free.argtypes = [ptr]; self.plist.plist_free.restype = None
        # IDEVICE_LOOKUP_USBMUX = 1 << 1; NEVER enable NETWORK / PREFER_NETWORK.
        self.check(self.lib.idevice_new_with_options(C.byref(self.device), udid.encode() if udid else None, 2), 'USB lookup (connect cable, unlock and trust)')

    @staticmethod
    def check(code, action):
        if code: raise RuntimeError('{}: error {}'.format(action, code))

    def vend(self, bundle):
        self.check(self.lib.house_arrest_client_start_service(self.device, C.byref(self.house), b'PhotoBridge-M0'), 'House Arrest / pairing')
        self.check(self.lib.house_arrest_send_command(self.house, b'VendDocuments', bundle.encode()), 'VendDocuments request')
        result = C.c_void_p()
        self.check(self.lib.house_arrest_get_result(self.house, C.byref(result)), 'VendDocuments response')
        try:
            if not result or self.plist.plist_dict_get_item(result, b'Error'):
                raise RuntimeError('VendDocuments denied: check installed bundle ID and File Sharing')
        finally:
            if result: self.plist.plist_free(result)
        self.check(self.lib.afc_client_new_from_house_arrest_client(self.house, C.byref(self.afc)), 'AFC Documents client')

    def list(self, path):
        names = C.POINTER(C.c_char_p)()
        self.check(self.lib.afc_read_directory(self.afc, documents_path(path).encode(), C.byref(names)), 'AFC list')
        try:
            result = []; index = 0
            while names[index]:
                result.append(names[index].decode('utf-8', errors='strict')); index += 1
            return [name for name in result if name not in ('.', '..')]
        finally: self.lib.afc_dictionary_free(names)

    def mkdir(self, path, exclusive=False):
        code = self.lib.afc_make_directory(self.afc, documents_path(path).encode())
        if not exclusive and code == 16: return  # AFC_E_OBJECT_EXISTS
        self.check(code, 'AFC mkdir (existing session is never reused)')

    def read(self, path, sink, maximum=None, offset=0):
        if type(offset) is not int or not 0 <= offset <= 2**63 - 1 or (maximum is not None and offset > maximum):
            raise ValueError('Invalid AFC resume offset')
        handle = C.c_uint64()
        self.check(self.lib.afc_file_open(self.afc, documents_path(path).encode(), 1, C.byref(handle)), 'AFC open read')
        total = offset
        try:
            if offset:
                self.check(self.lib.afc_file_seek(self.afc, handle, offset, os.SEEK_SET), 'AFC seek for resume')
            while True:
                buffer = C.create_string_buffer(CHUNK); count = C.c_uint32()
                self.check(self.lib.afc_file_read(self.afc, handle, buffer, CHUNK, C.byref(count)), 'AFC read')
                if count.value == 0: break
                total += count.value
                if maximum is not None and total > maximum: raise ValueError('Remote file exceeds declared bound')
                sink(buffer.raw[:count.value])
        finally: self.check(self.lib.afc_file_close(self.afc, handle), 'AFC close read')

    def write_new(self, path, source):
        # Called only in a freshly created UUID session; fail if filename already exists.
        parent, name = path.rsplit('/', 1)
        if name in self.list(parent): raise FileExistsError(path)
        handle = C.c_uint64()
        self.check(self.lib.afc_file_open(self.afc, documents_path(path).encode(), 3, C.byref(handle)), 'AFC open write')
        def writer(data):
            count = C.c_uint32(); buffer = C.create_string_buffer(data)
            self.check(self.lib.afc_file_write(self.afc, handle, buffer, len(data), C.byref(count)), 'AFC write')
            return count.value
        try:
            while True:
                data = source.read(CHUNK)
                if not data: break
                write_all(writer, data)
        finally: self.check(self.lib.afc_file_close(self.afc, handle), 'AFC close write')

    def commit_new(self, source, destination):
        parent, name = destination.rsplit('/', 1)
        if source.rsplit('/', 1)[0] != parent: raise ValueError('Commit must stay in the same session directory')
        if name in self.list(parent): raise FileExistsError(destination)
        self.check(self.lib.afc_rename_path(self.afc, documents_path(source).encode(), documents_path(destination).encode()), 'AFC commit')

    def close(self):
        if self.afc: self.lib.afc_client_free(self.afc); self.afc = C.c_void_p()
        if self.house: self.lib.house_arrest_client_free(self.house); self.house = C.c_void_p()
        if self.device: self.lib.idevice_free(self.device); self.device = C.c_void_p()


def download(client, remote, local):
    import io
    remote = probe_directory(remote)
    if '/Outbox/' not in remote: raise ValueError('Download requires iPhone Outbox')
    receipt_data = io.BytesIO(); client.read(remote + '/receipt.json', receipt_data.write, 65536)
    receipt = json.loads(receipt_data.getvalue()); validate_receipt(receipt, 'iPhone')
    local.mkdir(parents=True, exist_ok=False)
    part = local / 'probe.bin.part'
    with part.open('xb') as f:
        client.read(remote + '/probe.bin', f.write, receipt['byteCount']); f.flush(); os.fsync(f.fileno())
    actual = inspect(part)
    if actual['sha256'] != receipt['sha256'] or actual['byteCount'] != receipt['byteCount']:
        raise ValueError('Download HASH_FAIL; partial preserved')
    # Atomic, exclusive destination creation (link refuses replacement).
    os.link(part, local / 'probe.bin')
    with (local / 'receipt.json').open('x') as f: json.dump(receipt, f, indent=2)
    return {'direction': 'iPhone-to-Mac', 'result': 'HASH_PASS', **actual}


def upload(client, local):
    import io
    local.mkdir(parents=True, exist_ok=False)
    receipt = generate(local / 'probe.bin')
    with (local / 'receipt.json').open('x') as f: json.dump(receipt, f, indent=2)
    client.mkdir('USBProbe'); client.mkdir('USBProbe/Inbox')
    remote = 'USBProbe/Inbox/' + str(uuid.uuid4()); client.mkdir(remote, exclusive=True)
    with (local / 'probe.bin').open('rb') as source: client.write_new(remote + '/probe.bin.part', source)
    h = hashlib.sha256(); count = 0
    def consume(data):
        nonlocal count
        h.update(data); count += len(data)
    client.read(remote + '/probe.bin.part', consume, receipt['byteCount'])
    if h.hexdigest() != receipt['sha256'] or count != receipt['byteCount']:
        raise ValueError('AFC readback HASH_FAIL; partial preserved')
    client.commit_new(remote + '/probe.bin.part', remote + '/probe.bin')
    client.write_new(remote + '/receipt.json', io.BytesIO(json.dumps(receipt).encode()))
    return {'direction': 'Mac-to-iPhone', 'result': 'AFC_READBACK_HASH_PASS', 'iPhoneAppVerification': 'NOT_RUN: tap verify in iPhone app', 'remote': remote, **receipt}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['discover', 'list-outbox', 'download', 'upload'])
    parser.add_argument('--udid', help='select USB device; not written into report')
    parser.add_argument('--bundle', default='com.photobridge.OrderProbe')
    parser.add_argument('--remote', help='USBProbe/Outbox/<UUID> from list-outbox')
    parser.add_argument('--local', type=Path, help='NEW local diagnostic session directory')
    args = parser.parse_args(); client = None; start = time.monotonic()
    report = {'transportRequested': 'USB_ONLY', 'physicalWiFiOffEvidence': 'NOT_RUN: manual cable/Wi-Fi-off test required', 'photosRoundTrip': 'NOT_RUN'}
    try:
        client = AFC(args.udid)
        if args.command == 'discover': report.update(status='AVAILABLE_UNVERIFIED', detail='USB device found; no House Arrest or transfer test performed')
        else:
            client.vend(args.bundle)
            if args.command == 'list-outbox': report.update(status='AVAILABLE_UNVERIFIED', sessions=client.list('USBProbe/Outbox'))
            else:
                if args.local is None: raise ValueError('--local must name a new directory')
                if args.command == 'download':
                    if not args.remote: raise ValueError('--remote is required')
                    result = download(client, args.remote, args.local)
                else: result = upload(client, args.local)
                report.update(result); report['seconds'] = time.monotonic() - start
                report['MiBPerSecondIncludingVerification'] = result['byteCount'] / CHUNK / report['seconds']
                report['status'] = 'HASH_VERIFIED_PHYSICAL_TEST_PENDING'
    except Exception as error:
        report.update(status='BLOCKED', error=str(error))
    finally:
        if client: client.close()
    print(json.dumps(report, indent=2))
    return 2 if report['status'] == 'BLOCKED' else 0


if __name__ == '__main__': sys.exit(main())
