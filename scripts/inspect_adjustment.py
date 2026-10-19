#!/usr/bin/env python3
"""Read-only diagnosis of adjustment plist differences; NEVER relaxes byte verification or rewrites media."""
import argparse
import base64
import binascii
import datetime
import json
import math
from pathlib import Path
import plistlib
import re
from xml.parsers import expat


class DuplicatePlistKey(ValueError): pass


class UniqueKeys(dict):
    def __setitem__(self, key, value):
        if key in self: raise DuplicatePlistKey('Duplicate property list key')
        super().__setitem__(key, value)


def validate_xml(data):
    """plistlib ignores unknown tags; accept only an unambiguous XML plist grammar."""
    parser = expat.ParserCreate(); stack = []; roots = 0; signature = []; root_key = None
    values = {'dict', 'array', 'string', 'data', 'date', 'integer', 'real', 'true', 'false'}
    def reject(*unused): raise ValueError('Unsupported XML property list structure')
    def start(name, attributes):
        nonlocal roots
        if len(stack) >= 256: reject()
        if not stack:
            roots += 1
            if roots != 1 or name != 'plist' or attributes != {'version': '1.0'}: reject()
        else:
            parent, count, _ = stack[-1]
            if attributes: reject()
            if parent == 'plist':
                if count != 0 or name != 'dict': reject()
            elif parent == 'dict':
                if (count % 2 == 0 and name != 'key') or (count % 2 == 1 and name not in values): reject()
            elif parent == 'array':
                if name not in values: reject()
            else: reject()
            stack[-1][1] += 1
        stack.append([name, 0, []])
        if name in {'plist', 'dict', 'array'}: signature.append(('start', name))
    def end(name):
        nonlocal root_key
        element, count, fragments = stack.pop(); text = ''.join(fragments)
        if name != element or (name == 'dict' and count % 2) or (name == 'plist' and count != 1): reject()
        if name == 'date':
            if not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z', text): reject()
            datetime.datetime.strptime(text, '%Y-%m-%dT%H:%M:%SZ')
        if name == 'data':
            encoded = re.sub(r'[ \t\r\n]', '', text).encode('ascii')
            # Reject trailing junk, extra padding and nonzero unused padding bits.
            if base64.b64encode(base64.b64decode(encoded, validate=True)) != encoded: reject()
        if name == 'integer':
            if not re.fullmatch(r'[+-]?[0-9]+', text) or not -(2**63) <= int(text) < 2**64: reject()
        if name == 'real':
            if not re.fullmatch(r'[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?', text) or not math.isfinite(float(text)): reject()
        if name in {'plist', 'dict', 'array'}: signature.append(('end', name))
        else:
            if name == 'key' and len(stack) == 2: root_key = text
            signature.append((name, '<authorized-time>' if name == 'date' and len(stack) == 2 and root_key == 'adjustmentTimestamp' else text))
    def characters(text):
        if stack and stack[-1][0] in {'plist', 'dict', 'array', 'true', 'false'} and text.strip(): reject()
        if stack and stack[-1][0] not in {'plist', 'dict', 'array'}: stack[-1][2].append(text)
    parser.StartElementHandler = start; parser.EndElementHandler = end; parser.CharacterDataHandler = characters
    parser.EntityDeclHandler = reject; parser.ExternalEntityRefHandler = reject
    parser.StartCdataSectionHandler = reject; parser.ProcessingInstructionHandler = reject; parser.CommentHandler = reject
    parser.Parse(data, True)
    if roots != 1 or stack: reject()
    return signature


def equal_values(left, right):
    if type(left) is not type(right): return False
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(equal_values(left[k], right[k]) for k in left)
    if isinstance(left, list):
        return len(left) == len(right) and all(equal_values(a, b) for a, b in zip(left, right))
    return left == right


def analyze(original, restored):
    identical = original == restored
    result = {'binaryIdentical': identical, 'strictByteVerificationPass': identical}
    if identical: return dict(result, classification='IDENTICAL_BYTES', changedTopLevelKeys=[])
    if len(original) > 4 * 1024 * 1024 or len(restored) > 4 * 1024 * 1024:
        return dict(result, classification='NOT_INSPECTED_SIZE_LIMIT')
    try:
        before_xml = validate_xml(original); after_xml = validate_xml(restored)
        before = plistlib.loads(original, dict_type=UniqueKeys); after = plistlib.loads(restored, dict_type=UniqueKeys)
    except DuplicatePlistKey:
        return dict(result, classification='AMBIGUOUS_PROPERTY_LIST')
    except (ValueError, TypeError, OverflowError, plistlib.InvalidFileException, expat.ExpatError, binascii.Error):
        return dict(result, classification='UNPARSEABLE_PROPERTY_LIST')
    if not isinstance(before, dict) or not isinstance(after, dict):
        return dict(result, classification='UNSUPPORTED_PROPERTY_LIST_ROOT')
    changed = sorted(k for k in before.keys() | after.keys()
                     if k not in before or k not in after or not equal_values(before[k], after[k]))
    time_only = (changed == ['adjustmentTimestamp']
                 and before_xml == after_xml
                 and type(before.get('adjustmentTimestamp')) is datetime.datetime
                 and type(after.get('adjustmentTimestamp')) is datetime.datetime)
    return dict(result, classification='ADJUSTMENT_TIMESTAMP_ONLY_DIFFERENCE' if time_only else 'OTHER_PROPERTY_LIST_DIFFERENCE',
                changedTopLevelKeys=changed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('original', type=Path); parser.add_argument('restored', type=Path)
    args = parser.parse_args()
    for path in [args.original, args.restored]:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 4 * 1024 * 1024:
            raise ValueError('Expected a regular plist no larger than 4 MiB')
    print(json.dumps(analyze(args.original.read_bytes(), args.restored.read_bytes()), indent=2))


if __name__ == '__main__': main()
