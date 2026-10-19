#!/usr/bin/env python3
"""Read-only diagnosis of adjustment plist differences; NEVER relaxes byte verification or rewrites media."""
import argparse
import datetime
import json
from pathlib import Path
import plistlib


class DuplicatePlistKey(ValueError): pass


class UniqueKeys(dict):
    def __setitem__(self, key, value):
        if key in self: raise DuplicatePlistKey('Duplicate property list key')
        super().__setitem__(key, value)


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
        before = plistlib.loads(original, dict_type=UniqueKeys); after = plistlib.loads(restored, dict_type=UniqueKeys)
    except DuplicatePlistKey:
        return dict(result, classification='AMBIGUOUS_PROPERTY_LIST')
    except (ValueError, TypeError, OverflowError, plistlib.InvalidFileException):
        return dict(result, classification='UNPARSEABLE_PROPERTY_LIST')
    if not isinstance(before, dict) or not isinstance(after, dict):
        return dict(result, classification='UNSUPPORTED_PROPERTY_LIST_ROOT')
    changed = sorted(k for k in before.keys() | after.keys()
                     if k not in before or k not in after or not equal_values(before[k], after[k]))
    time_only = (changed == ['adjustmentTimestamp']
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
