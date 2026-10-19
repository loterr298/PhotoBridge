import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from device_restore_audit import audit
import test_album_restore as restore_tests


class IndependentAuditChecks(unittest.TestCase):
    def fixture(self, root):
        source = root / 'source'; source.mkdir()
        manifest, resources = restore_tests.RestoreChecks().fixture(source)
        report = dict(status='PHOTO_LIBRARY_BYTES_AND_ORDER_VERIFIED',
            sourceToCreatedAssetIDs={'id-1': 'new-1', 'id-2': 'new-2'},
            observedCreatedAssetIDs=['new-1', 'new-2'], createdAssets=2, resourcesVerifiedAssets=2,
            authorizedAdjustmentTimestampDifferences=0, strictBytesIdenticalForVerifiedAssets=True)
        files = {'album-order.json': (source / 'album-order.json').read_bytes()}
        files.update({'verification/' + name: data for name, data in resources.items()})
        for asset in manifest['assets']:
            files[f'verification/{asset["ordinal"]:06d}-resources.json'] = json.dumps(asset['resources']).encode()

        class Client:
            def read(self, path, sink, maximum=None):
                name = path.split('/', 2)[2]
                data = json.dumps(report).encode() if name == 'restore-report.json' else files[name]
                if maximum is not None and len(data) > maximum: raise ValueError('exceeds bound')
                sink(data)
        return source, manifest, report, files, Client()

    def test_audit_requires_actual_bytes_even_when_phone_report_says_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source, manifest, report, files, client = self.fixture(root)
            remote = 'RestoreInbox/' + manifest['sessionID']
            result = audit(client, remote, source, root / 'good')
            self.assertEqual(result['independentMacShasumMatches'], 2)
            self.assertTrue(result['strictBytesIdentical'])
            files['verification/' + manifest['assets'][0]['resources'][0]['storedRelativePath']] = b'corrupt'
            with self.assertRaisesRegex(ValueError, 'hash/size'):
                audit(client, remote, source, root / 'corrupt')
            self.assertFalse((root / 'corrupt/independent-audit.json').exists())

    def test_bad_order_unapproved_policy_and_unsafe_paths_cannot_pass(self):
        for fault in ['order', 'policy', 'path', 'nested-output']:
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); source, manifest, report, files, client = self.fixture(root)
                output = root / 'audit'
                if fault == 'order': report['observedCreatedAssetIDs'].reverse()
                if fault == 'policy': report['status'] = 'PHOTO_LIBRARY_NON_TIME_DATA_AND_ORDER_VERIFIED_WITH_AUTHORIZED_EDIT_TIMESTAMPS'
                if fault == 'path':
                    resources = copy.deepcopy(manifest['assets'][0]['resources'])
                    resources[0]['storedRelativePath'] = '../outside'
                    files['verification/000001-resources.json'] = json.dumps(resources).encode()
                if fault == 'nested-output': output = source / 'audit'
                with self.assertRaises(ValueError):
                    audit(client, 'RestoreInbox/' + manifest['sessionID'], source, output)
                self.assertFalse((output / 'independent-audit.json').exists())

    def test_unknown_xml_change_cannot_pass_the_complete_audit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source, manifest, report, files, client = self.fixture(root)
            def sidecar(payload, year):
                return ('<plist version="1.0"><dict><unknown>' + payload +
                    '</unknown><key>adjustmentTimestamp</key><date>' + year +
                    '-01-01T00:00:00Z</date></dict></plist>').encode()
            before = sidecar('BAD', '2020'); after = sidecar('XYZ', '2026')
            resource = manifest['assets'][0]['resources'][0]
            resource.update(resourceType=7, originalFilename='edit.plist', uniformTypeIdentifier='com.apple.property-list',
                storedRelativePath='Resources/000001/0001.plist', byteCount=len(before), sha256=hashlib.sha256(before).hexdigest())
            (source / resource['storedRelativePath']).write_bytes(before)
            raw = json.dumps(manifest).encode(); (source / 'album-order.json').write_bytes(raw); files['album-order.json'] = raw
            restored = dict(resource, sha256=hashlib.sha256(after).hexdigest())
            files['verification/000001-resources.json'] = json.dumps([restored]).encode()
            files['verification/' + resource['storedRelativePath']] = after
            report.update(status='PHOTO_LIBRARY_NON_TIME_DATA_AND_ORDER_VERIFIED_WITH_AUTHORIZED_EDIT_TIMESTAMPS',
                userAuthorizedAdjustmentTimestampRewrite=True, authorizedAdjustmentTimestampDifferences=1,
                strictBytesIdenticalForVerifiedAssets=False)
            with self.assertRaisesRegex(ValueError, 'Unapproved edit sidecar'):
                audit(client, 'RestoreInbox/' + manifest['sessionID'], source, root / 'audit', True)
            self.assertFalse((root / 'audit/independent-audit.json').exists())


if __name__ == '__main__': unittest.main()
