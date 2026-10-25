import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import test_album_export
import test_upload_resume
import album_export
import album_restore
import upload_resume
from transfer_control import CancellationRequested


class BatchScalingChecks(unittest.TestCase):
    def test_known_upload_journal_is_readable_before_usb_writes_and_tracks_completion(self):
        helper = test_upload_resume.UploadContinuationChecks(); helper.setUp()
        with tempfile.TemporaryDirectory() as d:
            source, _, _, _, client, _, _ = helper.setup_files(Path(d)); client.interrupted = False
            identity = 'DD54D37E-4327-4A3F-BDA7-91DC8EE4FDD4'
            journal = source / 'restore-uploads' / (identity + '.json')
            real = client.write_new; observed = []
            def write(path, stream):
                if not observed:
                    observed.append(json.loads(journal.read_bytes())['state'])
                real(path, stream)
            client.write_new = write
            result = upload_resume.upload(client, source, journal_id=identity)
            self.assertEqual(observed, ['UPLOADING'])
            self.assertEqual(result['journal'], str(journal))
            self.assertEqual(json.loads(journal.read_bytes())['state'], 'USB_VERIFIED')
            self.assertEqual(json.loads(journal.read_bytes())['resourcesVerified'], 2)

    def test_known_upload_journal_refuses_collision_without_replacing_old_bytes(self):
        helper = test_upload_resume.UploadContinuationChecks(); helper.setUp()
        with tempfile.TemporaryDirectory() as d:
            source, phone, _, _, client, writes, _ = helper.setup_files(Path(d)); client.interrupted = False
            identity = 'DD54D37E-4327-4A3F-BDA7-91DC8EE4FDD4'
            journals = source / 'restore-uploads'; journals.mkdir()
            journal = journals / (identity + '.json'); journal.write_bytes(b'previous-user-record')
            with self.assertRaises(FileExistsError): upload_resume.upload(client, source, journal_id=identity)
            self.assertEqual(journal.read_bytes(), b'previous-user-record')
            self.assertEqual(writes, []); self.assertEqual(list(phone.iterdir()), [])

    def test_flat_upload_uses_the_exact_hidden_progress_path_without_subdirectories(self):
        helper = test_upload_resume.UploadContinuationChecks(); helper.setUp()
        with tempfile.TemporaryDirectory() as d:
            source, _, _, _, client, _, _ = helper.setup_files(Path(d)); client.interrupted = False
            flat = Path(d) / 'flat'; album_export.organize_local_album(source, flat)
            identity = 'DD54D37E-4327-4A3F-BDA7-91DC8EE4FDD4'
            result = upload_resume.upload(client, flat, journal_id=identity)
            expected = flat / ('.photobridge-upload-' + identity + '.json')
            self.assertEqual(result['journal'], str(expected))
            self.assertEqual(json.loads(expected.read_bytes())['resourcesVerified'], 2)
            self.assertFalse(any(p.is_dir() for p in flat.iterdir()))

    def test_upload_progress_identity_cannot_escape_backup(self):
        for identity in ['../../outside', 'not-a-uuid', 'DD54D37E43274A3FBDA791DC8EE4FDD4']:
            with self.subTest(identity=identity), tempfile.TemporaryDirectory() as d:
                source = Path(d) / 'source'; source.mkdir()
                with self.assertRaises(ValueError): upload_resume.upload(None, source, journal_id=identity)
                self.assertEqual(list(source.iterdir()), [])

    def test_legacy_download_hashes_the_immutable_manifest_once(self):
        fixture = test_album_export.AlbumExportChecks(); m, files = fixture.fixture()
        raw = json.dumps(m).encode(); real = hashlib.sha256; calls = []
        def sha(data=b''):
            if data == raw: calls.append(len(data))
            return real(data)
        with tempfile.TemporaryDirectory() as d, mock.patch.object(album_export.hashlib, 'sha256', side_effect=sha):
            album_export.download_album(fixture.client(m, files), 'Exports/' + m['sessionID'], Path(d) / 'new')
        self.assertEqual(len(calls), 1, 'Do not hash the complete manifest for every resource')

    def test_owned_upload_parses_the_large_manifest_only_once(self):
        helper = test_upload_resume.UploadContinuationChecks(); helper.setUp()
        with tempfile.TemporaryDirectory() as d:
            source, _, _, _, client, _, _ = helper.setup_files(Path(d)); client.interrupted = False
            raw = (source / 'album-order.json').read_bytes(); real = json.loads; parses = []
            def loads(value, *args, **kwargs):
                if value == raw: parses.append(1)
                return real(value, *args, **kwargs)
            with mock.patch.object(album_restore.json, 'loads', side_effect=loads): upload_resume.upload(client, source)
            self.assertEqual(len(parses), 1, 'Publication must rehash resources without rebuilding the complete metadata graph')

    def test_local_resource_change_after_usb_commit_still_blocks_publication(self):
        helper = test_upload_resume.UploadContinuationChecks(); helper.setUp()
        with tempfile.TemporaryDirectory() as d:
            source, phone, _, files, client, _, _ = helper.setup_files(Path(d)); client.interrupted = False
            real = client.commit_new; changed = []
            def commit(part, final):
                real(part, final)
                if '/Resources/' in final and not changed:
                    (source / next(iter(files))).write_bytes(b'changed-after-usb-readback'); changed.append(True)
            client.commit_new = commit
            with self.assertRaisesRegex(ValueError, 'Local backup'): upload_resume.upload(client, source)
            self.assertTrue(changed); self.assertFalse(list(phone.rglob('restore-request.json')))

    def test_local_validation_can_stop_between_resource_hashes(self):
        helper = test_upload_resume.UploadContinuationChecks(); helper.setUp()
        with tempfile.TemporaryDirectory() as d:
            source, _, _, _, _, _, _ = helper.setup_files(Path(d)); cancel = Path(d) / 'stop'
            real = album_restore.inspect; reads = []
            def inspect(path):
                reads.append(path); result = real(path); cancel.write_text('stop'); return result
            with mock.patch.object(album_restore, 'inspect', side_effect=inspect), self.assertRaises(CancellationRequested):
                album_restore.validated_backup(source, cancel_file=cancel)
            self.assertEqual(len(reads), 1)

    def test_remote_resume_prescan_can_stop_before_reading_the_next_resource(self):
        helper = test_upload_resume.UploadContinuationChecks(); helper.setUp()
        with tempfile.TemporaryDirectory() as d:
            source, phone, _, files, client, _, _, journal = helper.interrupted(Path(d))
            cancel = Path(d) / 'stop'; old_journal = journal.read_bytes(); reads = []
            real = client.read
            def read(path, sink, maximum=None):
                if '/Resources/' in path: reads.append(path)
                real(path, sink, maximum)
                if '/Resources/' in path: cancel.write_text('stop')
            client.read = read
            with self.assertRaises(CancellationRequested): upload_resume.upload(client, source, journal, cancel)
            self.assertEqual(len(reads), 1, 'Pause must apply during reuse verification, before the next resource')
            self.assertEqual(journal.read_bytes(), old_journal)
            self.assertFalse(list(phone.rglob('restore-request.json')))

    def test_conflicting_source_and_asset_creation_dates_are_rejected(self):
        m, _ = test_album_export.AlbumExportChecks().fixture()
        m['sourceOrder']['members'][0]['creationDate'] = '2001-01-01T00:00:00Z'
        m['assets'][0]['originalPhotoLibraryCreationDate'] = '2002-01-01T00:00:00Z'
        with self.assertRaises(ValueError): album_export.validate_manifest(m)
        m['assets'][0]['originalPhotoLibraryCreationDate'] = '2001-01-01T00:00:00+00:00'
        album_export.validate_manifest(m)

    def test_flat_marker_version_must_be_an_integer_not_a_json_boolean(self):
        from backup_layout import is_flat
        for value in (True, 1.0):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as d:
                root = Path(d); (root / '.photobridge-layout.json').write_text(json.dumps({'kind': 'PhotoBridgeFlatAlbum', 'version': value}))
                with self.assertRaises(ValueError): is_flat(root)

    def test_fast_ready_files_coalesce_status_polls_but_recheck_before_commit(self):
        m, files = test_album_export.AlbumExportChecks().fixture(); request = '9d4933c5-c0ef-4b67-9698-2c47077cd84d'
        class Client:
            polls = 0
            fail_at_commit = False
            def read(self, path, sink, maximum=None):
                if path.startswith('Control/Jobs/'):
                    self.polls += 1
                    value = {'requestID': request, 'albumIdentifier': 'album-test', 'sessionID': m['sessionID'], 'status': 'FAILED' if self.fail_at_commit and self.polls == 2 else 'STAGED'}
                elif path.endswith('/source-order.json'): value = m['sourceOrder']
                elif '/asset-records/' in path: value = m['assets'][int(Path(path).stem) - 1]
                elif path.endswith('/album-order.json'): value = m
                else: sink(files[path.split(m['sessionID'] + '/')[1]]); return
                sink(json.dumps(value).encode())
        with tempfile.TemporaryDirectory() as d:
            client = Client(); result = album_export.download_live_album(client, request, 'album-test', Path(d) / 'new', status_interval=60)
            self.assertEqual(result['status'], 'COMMITTED'); self.assertEqual(client.polls, 2)

        with tempfile.TemporaryDirectory() as d:
            client = Client(); client.fail_at_commit = True; target = Path(d) / 'failed'
            with self.assertRaises(RuntimeError): album_export.download_live_album(client, request, 'album-test', target, status_interval=60)
            self.assertFalse((target / 'album-order.json').exists())
            self.assertFalse((target / 'transfer-manifest.json').exists())
