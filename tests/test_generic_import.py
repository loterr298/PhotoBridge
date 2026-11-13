import hashlib
import json
import os
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'scripts'))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import album_restore
import test_upload_resume


class GenericFolderImportChecks(unittest.TestCase):
    def test_plain_folder_uses_exported_filesystem_time_when_manifest_is_missing(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d) / 'Photos'; root.mkdir()
            first = root / 'IMG_9000.JPG'; second = root / 'IMG_0001.JPG'
            first.write_bytes(b'first'); second.write_bytes(b'second')
            # This is the five-second logical time written by PhotoBridge when
            # a private manifest is unavailable to an older/new install.
            os.utime(first, (100, 100)); os.utime(second, (105, 105))
            staging_root = pathlib.Path(d) / 'staging'
            os.environ['PHOTOBRIDGE_IMPORT_STAGING_ROOT'] = str(staging_root)
            try:
                staging = album_restore.prepare_import_backup(root)
                _, manifest, _, _, _ = album_restore.validated_backup(staging)
            finally:
                os.environ.pop('PHOTOBRIDGE_IMPORT_STAGING_ROOT', None)
            self.assertEqual([a['resources'][0]['originalFilename'] for a in manifest['assets']],
                             ['IMG_9000.JPG', 'IMG_0001.JPG'])

    def test_plain_folder_reports_scan_progress_before_hashing_finishes(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d) / 'Photos'; root.mkdir()
            (root / '02 beach.JPG').write_bytes(b'beach')
            (root / '01 home.HEIC').write_bytes(b'home')
            progress = []
            staging_root = pathlib.Path(d) / 'staging'
            os.environ['PHOTOBRIDGE_IMPORT_STAGING_ROOT'] = str(staging_root)
            try:
                album_restore.prepare_import_backup(root, progress=progress.append)
            finally:
                os.environ.pop('PHOTOBRIDGE_IMPORT_STAGING_ROOT', None)
            self.assertGreaterEqual(len(progress), 3)
            self.assertEqual(progress[0]['status'], 'SCANNING')
            self.assertEqual(progress[0]['scannedAssets'], 0)
            self.assertEqual(progress[0]['scanTotalAssets'], 2)
            self.assertEqual(progress[-1]['scannedAssets'], 2)
            self.assertEqual(progress[-1]['scanTotalAssets'], 2)

    def test_plain_photo_folder_builds_ordered_private_backup_without_writing_source(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d) / 'Photos from Mac'
            root.mkdir()
            (root / '02 beach.JPG').write_bytes(b'beach')
            (root / '01 home.HEIC').write_bytes(b'home')
            (root / 'notes.txt').write_text('ignore')
            staging_root = pathlib.Path(d) / 'staging'
            old_listing = sorted(p.name for p in root.iterdir())
            old_bytes = {p.name: p.read_bytes() for p in root.iterdir()}
            os.environ['PHOTOBRIDGE_IMPORT_STAGING_ROOT'] = str(staging_root)
            try:
                staging = album_restore.prepare_import_backup(root)
                raw, manifest, resources, digest, total = album_restore.validated_backup(staging)
            finally:
                os.environ.pop('PHOTOBRIDGE_IMPORT_STAGING_ROOT', None)
            self.assertEqual([a['resources'][0]['originalFilename'] for a in manifest['assets']], ['01 home.HEIC', '02 beach.JPG'])
            self.assertEqual([a['ordinal'] for a in manifest['assets']], [1, 2])
            self.assertEqual([r['byteCount'] for r in resources], [4, 5])
            self.assertEqual(total, 9)
            self.assertEqual(sorted(p.name for p in root.iterdir()), old_listing)
            self.assertEqual({p.name: p.read_bytes() for p in root.iterdir()}, old_bytes)
            self.assertEqual(hashlib.sha256(raw).hexdigest(), digest)

    def test_plain_folder_reuses_same_private_backup_for_continuation(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d) / 'Photos'; root.mkdir()
            (root / 'b.jpg').write_bytes(b'b'); (root / 'a.jpg').write_bytes(b'a')
            staging_root = pathlib.Path(d) / 'staging'
            os.environ['PHOTOBRIDGE_IMPORT_STAGING_ROOT'] = str(staging_root)
            try:
                first = album_restore.prepare_import_backup(root)
                second = album_restore.prepare_import_backup(root)
            finally:
                os.environ.pop('PHOTOBRIDGE_IMPORT_STAGING_ROOT', None)
            self.assertEqual(first, second)
            self.assertEqual(json.loads((first / 'transfer-manifest.json').read_text())['status'], 'COMMITTED')

    def test_upload_accepts_plain_folder_and_keeps_source_folder_clean(self):
        with tempfile.TemporaryDirectory() as d:
            base = pathlib.Path(d)
            source, phone, _, _, client, _, _ = test_upload_resume.UploadContinuationChecks().setup_files(base)
            plain = base / 'plain'; plain.mkdir()
            (plain / '02.JPG').write_bytes(b'two')
            (plain / '01.HEIC').write_bytes(b'one')
            before = sorted(p.name for p in plain.iterdir())
            os.environ['PHOTOBRIDGE_IMPORT_STAGING_ROOT'] = str(base / 'staging')
            try:
                import upload_resume
                # This test covers accepting a plain folder; interruption is
                # covered by UploadContinuationChecks separately.
                client.interrupted = False
                result = upload_resume.upload(client, plain)
            finally:
                os.environ.pop('PHOTOBRIDGE_IMPORT_STAGING_ROOT', None)
            self.assertEqual(result['state'], 'USB_VERIFIED')
            self.assertEqual(sorted(p.name for p in plain.iterdir()), before)


if __name__ == '__main__': unittest.main()
