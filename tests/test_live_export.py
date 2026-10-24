import copy
import json
import pathlib
import sys
import tempfile
import unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'scripts'))
import test_album_export
import album_export


class LiveExportChecks(unittest.TestCase):
    def run_export(self, mode='normal'):
        m, files = test_album_export.AlbumExportChecks().fixture()
        request = '9d4933c5-c0ef-4b67-9698-2c47077cd84d'
        with tempfile.TemporaryDirectory() as directory:
            target = pathlib.Path(directory) / 'new'
            previous = None
            if mode in ('reuse', 'corrupt-old'):
                previous = pathlib.Path(directory) / 'previous'; previous.mkdir()
                (previous / 'transfer-progress.json').write_text(json.dumps({'albumIdentifier': 'album-test'}))
                for path, data in files.items():
                    old = previous / path; old.parent.mkdir(parents=True, exist_ok=True)
                    old.write_bytes(data if mode == 'reuse' else b'changed-old')
                old_bytes = {path: (previous / path).read_bytes() for path in files}
            class Client:
                status_reads = 0
                connected = True
                failed_media = False
                def reconnect(self): self.connected = True
                def read(self, path, sink, maximum=None):
                    if path == 'Control/Jobs/' + request + '.json':
                        self.status_reads += 1
                        if mode == 'mux-status' and self.status_reads == 1:
                            self.connected = False
                        if not self.connected: raise RuntimeError('AFC open read: error 30')
                        if mode == 'transient-status' and self.status_reads in (1, 5):
                            # Real AFC failure observed while iOS atomically replaced
                            # the status file. A partial reply must be discarded.
                            sink(b'{\"requestID\":')
                            raise RuntimeError('AFC read: error 1')
                        if mode == 'persistent-status':
                            if self.status_reads > 4: raise AssertionError('Unbounded retry')
                            raise RuntimeError('AFC read: error 1')
                        if mode == 'background' and self.status_reads == 4:
                            self_test.assertIs(json.loads((target / 'transfer-progress.json').read_text()).get('phoneInForeground'), False)
                        status = {'requestID': request, 'albumIdentifier': 'album-test',
                                  'sessionID': m['sessionID'], 'status': 'STAGING'}
                        if mode == 'background': status['phoneInForeground'] = self.status_reads > 4
                        if mode == 'stale': status['requestID'] = 'another-request'
                        if mode == 'failed': status.update(status='FAILED', error='cloud original missing')
                        value = json.dumps(status).encode()
                    else:
                        name = path.split('/' + m['sessionID'] + '/', 1)[1]
                        if name == 'source-order.json': value = json.dumps(m['sourceOrder']).encode()
                        elif name.startswith('asset-records/'):
                            ordinal = int(pathlib.PurePosixPath(name).stem)
                            if ordinal == 2:
                                # Temporal acceptance: first photo must be on disk
                                # before the second photo is even available remotely.
                                self_test.assertEqual((target / next(iter(files))).read_bytes(), next(iter(files.values())))
                                self_test.assertFalse((target / 'album-order.json').exists())
                            record = copy.deepcopy(m['assets'][ordinal-1])
                            if mode == 'unsafe': record['resources'][0]['storedRelativePath'] = '../outside'
                            value = json.dumps(record).encode()
                        elif name == 'album-order.json':
                            final = copy.deepcopy(m)
                            if mode == 'changed-final': final['assets'][0]['resourceGroupId'] = m['assets'][1]['resourceGroupId']
                            value = json.dumps(final).encode()
                        else:
                            if mode == 'reuse': raise AssertionError('Verified old media was fetched over USB again')
                            value = files[name]
                            if mode == 'mux-media' and not self.failed_media:
                                self.failed_media = True; self.connected = False
                                sink(value[:3]); raise RuntimeError('AFC read: error 30')
                            if not self.connected: raise RuntimeError('AFC open read: error 30')
                            if mode == 'corrupt': value = value[:-1]
                    if maximum is not None and len(value) > maximum: raise ValueError('exceeds bound')
                    sink(value)
            self_test = self
            if mode not in ('normal', 'reuse', 'transient-status', 'mux-status', 'mux-media', 'background'):
                with self.assertRaises((ValueError, RuntimeError)):
                    album_export.download_live_album(Client(), request, 'album-test', target, previous=previous)
                self.assertFalse((target / 'transfer-manifest.json').exists())
            else:
                result = album_export.download_live_album(Client(), request, 'album-test', target, previous=previous)
                self.assertEqual(result['status'], 'COMMITTED')
                if mode == 'mux-media':
                    self.assertTrue(any(p.read_bytes() == next(iter(files.values()))[:3] for p in target.rglob('*.part')), 'Failed media attempt must be preserved')
                if mode == 'reuse':
                    self.assertEqual(result['reusedVerifiedResources'], 2)
                    for path, data in old_bytes.items(): self.assertEqual((previous / path).read_bytes(), data)
                self.assertEqual(result['assetsVerified'], 2)
                times = [(target / path).stat().st_mtime for path in files]
                self.assertEqual(times[1] - times[0], 5)
                self.assertEqual(json.loads((target / 'album-order.json').read_text()), m)
                from album_restore import validated_backup
                validated_backup(target)

    def test_pause_while_waiting_preserves_journal_without_claiming_completion(self):
        from transfer_control import CancellationRequested
        request = '9d4933c5-c0ef-4b67-9698-2c47077cd84d'
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / 'new'; cancel = pathlib.Path(d) / 'cancel'
            class Client:
                def read(self, path, sink, maximum=None):
                    cancel.write_text('stop')
                    raise RuntimeError('AFC open read: error 8')
            with self.assertRaises(CancellationRequested):
                album_export.download_live_album(Client(), request, 'album-test', target, cancel)
            self.assertEqual(json.loads((target / 'transfer-progress.json').read_text())['status'], 'STOPPED')
            self.assertFalse((target / 'transfer-manifest.json').exists())

    def test_background_phone_is_reported_without_failing_and_clears_when_active(self):
        self.run_export('background')

    def test_lost_metadata_service_reconnects_without_restarting_phone_export(self):
        try: self.run_export('mux-status')
        except RuntimeError as error: self.fail('Must reconnect the existing service: ' + str(error))

    def test_lost_media_service_preserves_partial_and_commits_a_fresh_verified_copy(self):
        try: self.run_export('mux-media')
        except RuntimeError as error: self.fail('Must safely retry interrupted media read: ' + str(error))

    def test_status_replacement_read_error_retries_without_losing_or_duplicating_bytes(self):
        try:
            self.run_export('transient-status')
        except RuntimeError as error:
            self.fail('Connected iPhone status read must survive transient AFC error: ' + str(error))

    def test_persistent_status_error_stops_without_claiming_completion(self):
        self.run_export('persistent-status')

    def test_continuation_reuses_verified_bytes_without_usb_media_reads(self): self.run_export('reuse')
    def test_corrupt_previous_copy_is_never_reused(self): self.run_export('corrupt-old')

    def test_first_photo_is_saved_before_complete_manifest_exists(self): self.run_export()
    def test_stale_request_never_transfers_an_old_session(self): self.run_export('stale')
    def test_phone_failure_never_claims_success(self): self.run_export('failed')
    def test_corrupt_media_never_commits(self): self.run_export('corrupt')
    def test_unsafe_record_path_is_rejected(self): self.run_export('unsafe')
    def test_final_manifest_must_match_streamed_records(self): self.run_export('changed-final')
