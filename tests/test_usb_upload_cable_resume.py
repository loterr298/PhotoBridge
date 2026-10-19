from pathlib import Path
import json
import tempfile
import unittest
from unittest.mock import patch
import device_usb_upload_cable_resume as cable
import test_upload_resume


class UploadCableClassificationChecks(unittest.TestCase):
    def test_full_size_part_cannot_claim_positive_suffix_continuation(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); helper = test_upload_resume.UploadContinuationChecks(); helper.setUp()
            source, phone, _, files, client, writes, offsets, previous = helper.interrupted(root)
            remote = json.loads(previous.read_bytes())['remote']; second = list(files)[1]
            (phone / remote / (second + '.part')).write_bytes(files[second])
            out = root / 'evidence'; out.mkdir()
            for name, value in {
                'interruption.json': {'status': 'CABLE_FAILURE_OBSERVED_PENDING_PARTIAL_INSPECTION'},
                'source.json': {'source': str(source)}, 'source-state.json': cable.source_snapshot(source),
                'journal-location.json': {'journal': str(previous)}
            }.items(): (out / name).write_text(json.dumps(value))
            (out / 'interrupted-journal.json').write_bytes(previous.read_bytes())
            client.vend = lambda bundle: None; client.close = lambda: None; writes.clear()
            with patch.object(cable, 'AFC', return_value=client), patch.object(cable, 'usb_phone_present', return_value=True):
                with self.assertRaisesRegex(ValueError, 'No strict partial'): cable.resume(out)
            self.assertEqual(offsets, []); self.assertEqual(writes, [])
            self.assertFalse((out / 'physical-upload-summary.json').exists())

    def test_local_reader_error_cannot_be_reported_as_usb_write_failure(self):
        for local_error in [True, False]:
            with self.subTest(local_error=local_error), tempfile.TemporaryDirectory() as directory:
                class Source:
                    def read(self, size):
                        if local_error: raise RuntimeError('local source failed')
                        return b'prefix'
                class Client:
                    def vend(self, bundle): pass
                    def close(self): pass
                    def write_new(self, path, source):
                        source.read(1024)
                        raise RuntimeError('AFC write: error 30')
                def upload(client, source): client.write_new('RestoreInbox/test/Resources/000001/0001.JPG.part', Source())
                calls = 0
                def present():
                    nonlocal calls
                    calls += 1
                    return calls == 1
                with patch.object(cable, 'AFC', Client), patch.object(cable, 'upload', upload), \
                        patch.object(cable, 'usb_phone_present', present), patch.object(cable, 'source_snapshot', return_value={}), \
                        patch.object(cable, 'validated_backup'), patch.object(cable.time, 'sleep'):
                    result = cable.interrupt(Path(directory) / 'source', Path(directory) / 'evidence')
                self.assertEqual(result['USBWriteFailure'] is None, local_error)
                self.assertEqual(result['status'], 'PHYSICAL_INTERRUPTION_NOT_PROVEN' if local_error
                    else 'CABLE_FAILURE_OBSERVED_PENDING_PARTIAL_INSPECTION')


if __name__ == '__main__': unittest.main()
