#!/usr/bin/env python3
"""Independent USB read-only Photos round-trip audit; private output, never uploads or changes Photos."""
import argparse
import copy
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from album_export import validate_manifest
from album_restore import regular_path
from inspect_adjustment import analyze
from usb_probe import AFC, inspect


def audit(client, remote, source, output, allow_timestamp=False):
    parts = remote.split('/')
    if len(parts) != 2 or parts[0] != 'RestoreInbox' or str(uuid.UUID(parts[1])) != parts[1].lower():
        raise ValueError('Expected RestoreInbox/<UUID>')
    source = Path(source); output = Path(output)
    if source.resolve() == output.resolve() or source.resolve() in output.resolve().parents:
        raise ValueError('Audit output must be outside the preserved source')
    raw = regular_path(source, 'album-order.json').read_bytes()
    manifest = json.loads(raw); validate_manifest(manifest)

    def read(relative, maximum=64 * 1024 * 1024):
        data = io.BytesIO(); client.read(remote + '/' + relative, data.write, maximum)
        return data.getvalue()

    if read('album-order.json') != raw: raise ValueError('Different source manifest')
    report_raw = read('restore-report.json'); report = json.loads(report_raw)
    strict_status = 'PHOTO_LIBRARY_BYTES_AND_ORDER_VERIFIED'
    allowed_status = 'PHOTO_LIBRARY_NON_TIME_DATA_AND_ORDER_VERIFIED_WITH_AUTHORIZED_EDIT_TIMESTAMPS'
    if report['status'] not in ([strict_status, allowed_status] if allow_timestamp else [strict_status]):
        raise ValueError('Phone did not complete the requested verification policy')
    identifiers = [a['sourceAssetLocalIdentifier'] for a in manifest['assets']]
    mapping = report['sourceToCreatedAssetIDs']; observed = report['observedCreatedAssetIDs']
    if (set(mapping) != set(identifiers) or len(set(mapping.values())) != len(identifiers)
            or observed != [mapping[key] for key in identifiers]
            or report['createdAssets'] != len(identifiers) or report['resourcesVerifiedAssets'] != len(identifiers)):
        raise ValueError('Incomplete mapping or incorrect PhotoKit member order')
    if allow_timestamp and report.get('userAuthorizedAdjustmentTimestampRewrite') is not True:
        raise ValueError('Phone authorization was not recorded')
    output.mkdir(mode=0o700, exist_ok=False)
    (output / 'restore-report.json').write_bytes(report_raw)
    candidate = copy.deepcopy(manifest)
    for asset in candidate['assets']:
        relative = f'verification/{asset["ordinal"]:06d}-resources.json'
        data = read(relative); (output / Path(relative).name).write_bytes(data)
        asset['resources'] = json.loads(data)
    validate_manifest(candidate)  # Reject unsafe paths/ordinals/types before using phone-provided paths.
    exact = changed = total = 0
    metadata = ['resourceType', 'originalFilename', 'uniformTypeIdentifier', 'byteCount']
    for original_asset, restored_asset in zip(manifest['assets'], candidate['assets']):
        remaining = list(original_asset['resources'])
        for restored in restored_asset['resources']:
            matches = [r for r in remaining if all(r[k] == restored[k] for k in metadata)]
            matches.sort(key=lambda r: r['sha256'] != restored['sha256'])
            if not matches: raise ValueError('Resource multiset metadata changed')
            original = matches[0]; remaining.remove(original)
            source_path = regular_path(source, original['storedRelativePath'])
            receipt = inspect(source_path)
            if any(receipt[k] != original[k] for k in ['sha256', 'byteCount']):
                raise ValueError('Source backup bytes changed')
            target = output / restored['storedRelativePath']; target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('xb') as stream:
                client.read(remote + '/verification/' + restored['storedRelativePath'], stream.write, restored['byteCount'])
            digest = subprocess.check_output(['/usr/bin/shasum', '-a', '256', str(target)], text=True).split()[0]
            if digest != restored['sha256'] or target.stat().st_size != restored['byteCount']:
                raise ValueError('Independent downloaded resource hash/size failed')
            total += restored['byteCount']
            if digest == original['sha256']: exact += 1
            elif allow_timestamp and original['resourceType'] == 7:
                if original['byteCount'] > 4 * 1024 * 1024:
                    raise ValueError('Edit sidecar exceeds inspection bound')
                difference = analyze(source_path.read_bytes(), target.read_bytes())
                if difference['classification'] != 'ADJUSTMENT_TIMESTAMP_ONLY_DIFFERENCE':
                    raise ValueError('Unapproved edit sidecar change')
                (target.with_suffix(target.suffix + '.difference.json')).write_text(json.dumps(difference, indent=2) + '\n')
                changed += 1
            else: raise ValueError('Unapproved resource byte change')
        if remaining: raise ValueError('Missing restored resource')
    if (read('restore-report.json') != report_raw or read('album-order.json') != raw
            or report['authorizedAdjustmentTimestampDifferences'] != changed
            or report['strictBytesIdenticalForVerifiedAssets'] != (changed == 0)):
        raise ValueError('Report changed or disagrees with independent audit')
    result = dict(status='INDEPENDENT_USB_AUDIT_PASS', assets=len(identifiers), resources=exact + changed,
        bytes=total, independentMacShasumMatches=exact + changed, sourceBytesIdenticalResources=exact,
        authorizedAdjustmentTimestampDifferences=changed, strictBytesIdentical=changed == 0,
        sourceToCreatedMappingVerified=True, photoKitNilOrderMatchesMapping=True,
        runtimeVersion=report.get('runtimeVersion'), runtimeBuild=report.get('runtimeBuild'),
        manualPhotosOrder='NOT_RUN_BY_THIS_SCRIPT', manualEditAppearance='NOT_RUN',
        sourceFilesWritten=False, phoneFilesWritten=False)
    (output / 'independent-audit.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--remote', required=True); parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--allow-authorized-adjustment-timestamp', action='store_true')
    args = parser.parse_args(); client = AFC()
    try:
        client.vend('com.photobridge.OrderProbe')
        print(json.dumps(audit(client, args.remote, args.source, args.output,
            args.allow_authorized_adjustment_timestamp), indent=2))
    finally: client.close()
