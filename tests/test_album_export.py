import copy, hashlib, importlib.util, json, pathlib, sys, tempfile, unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'scripts'))

class AlbumExportChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import album_export
        cls.module = album_export

    def fixture(self):
        files = {'Resources/000001/0001.HEIC': b'original-private-maker-notes', 'Resources/000002/0001.HEIC': b'another-original'}
        assets = []
        for i, (path, data) in enumerate(files.items(), 1):
            assets.append({'ordinal': i, 'resourceGroupId': f'12345678-1234-4234-8234-{i:012d}',
                'sourceAssetLocalIdentifier': f'id-{i}', 'pixelWidth': 20, 'pixelHeight': 10,
                'mediaType': 1, 'mediaSubtypes': 0, 'resources': [{'resourceIndex': 1, 'resourceType': 999,
                'originalFilename': 'same.HEIC', 'uniformTypeIdentifier': 'public.heic', 'storedRelativePath': path,
                'sha256': hashlib.sha256(data).hexdigest(), 'byteCount': len(data)}]})
        manifest = {'schemaVersion': '1.0.0', 'kind': 'PhotoBridgeOriginalExport',
            'sessionID': '12345678-1234-4234-8234-123456789abc', 'status': 'staged', 'intervalSeconds': 5,
            'timestampScope': 'new-Mac-copies-filesystem-only', 'restorationStatus': 'NOT_RUN',
            'sourceOrder': {'schemaVersion': '1.0.0', 'albumName': 'synthetic', 'albumIdentifier': 'album-test',
                'fetchMode': 'nil-options', 'systemVersion': 'synthetic', 'build': 'test', 'verification': 'NOT_RUN',
                'authorization': 'full', 'capturedAt': '2026-10-18T12:00:00Z',
                'members': [{'ordinal': i, 'localIdentifier': f'id-{i}'} for i in (1, 2)]}, 'assets': assets}
        return manifest, files

    def test_manifest_preserves_unknown_roles_but_rejects_incomplete_and_unsafe_paths(self):
        m, _ = self.fixture(); self.module.validate_manifest(m)
        bad = []
        for path in ['../original.HEIC', '/private/file', 'Resources/000002/0001.HEIC', 'Resources/000001/../../file']:
            x = copy.deepcopy(m); x['assets'][0]['resources'][0]['storedRelativePath'] = path; bad.append(x)
        for field, value in [('byteCount', 0), ('sha256', 'bad'), ('resourceType', 0)]:
            x = copy.deepcopy(m); x['assets'][0]['resources'][0][field] = value; bad.append(x)
        x = copy.deepcopy(m); x['assets'].pop(); bad.append(x)
        x = copy.deepcopy(m); x['assets'][0]['sourceAssetLocalIdentifier'] = 'replacement'; bad.append(x)
        x = copy.deepcopy(m); x['sourceOrder']['authorization'] = 'limited'; bad.append(x)
        x = copy.deepcopy(m); x['sourceOrder']['capturedAt'] = '2026-10-18T12:00:00'; bad.append(x)
        for x in bad:
            with self.assertRaises(ValueError): self.module.validate_manifest(x)

    def test_hidden_original_filename_uses_bin_extension_like_foundation(self):
        m, _ = self.fixture()
        r = m['assets'][0]['resources'][0]
        r['originalFilename'] = '.AAE'; r['storedRelativePath'] = 'Resources/000001/0001.bin'
        self.module.validate_manifest(m)

    def test_mixed_png_raw_and_live_pair_resources_keep_one_asset_group(self):
        m, _ = self.fixture()
        resources = m['assets'][0]['resources']
        resources.append({'resourceIndex': 2, 'resourceType': 2, 'originalFilename': 'pair.DNG',
            'uniformTypeIdentifier': 'com.adobe.raw-image', 'storedRelativePath': 'Resources/000001/0002.DNG',
            'sha256': 'b' * 64, 'byteCount': 4})
        resources.append({'resourceIndex': 3, 'resourceType': 3, 'originalFilename': 'pair.MOV',
            'uniformTypeIdentifier': 'com.apple.quicktime-movie', 'storedRelativePath': 'Resources/000001/0003.MOV',
            'sha256': 'c' * 64, 'byteCount': 5})
        m['assets'][1]['resources'][0]['originalFilename'] = 'preview.PNG'
        m['assets'][1]['resources'][0]['storedRelativePath'] = 'Resources/000002/0001.PNG'
        self.module.validate_manifest(m)

    def test_required_metadata_missing_or_wrong_type_cannot_commit(self):
        m, _ = self.fixture()
        for area, field in [('sourceOrder', 'albumIdentifier'), ('sourceOrder', 'albumName'),
                ('sourceOrder', 'fetchMode'), ('asset', 'pixelWidth'), ('asset', 'mediaType'),
                ('resource', 'uniformTypeIdentifier'), ('root', 'restorationStatus')]:
            for replacement in [None, []]:
                bad = copy.deepcopy(m)
                target = {'sourceOrder': bad['sourceOrder'], 'asset': bad['assets'][0],
                    'resource': bad['assets'][0]['resources'][0], 'root': bad}[area]
                if replacement is None: target.pop(field)
                else: target[field] = replacement
                with self.assertRaises((ValueError, KeyError, TypeError)): self.module.validate_manifest(bad)

    def client(self, manifest, files, corrupt=False):
        class Client:
            def read(self, path, sink, maximum=None):
                name = path.split('/12345678-1234-4234-8234-123456789abc/', 1)[1]
                data = json.dumps(manifest).encode() if name == 'album-order.json' else files[name]
                if corrupt and name != 'album-order.json': data = data[:-1]
                if maximum is not None and len(data) > maximum: raise ValueError('exceeds bound')
                for offset in range(0, len(data), 3): sink(data[offset:offset+3])
        return Client()

    def test_download_checks_real_bytes_then_assigns_five_second_mtimes(self):
        m, files = self.fixture()
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / 'new'
            result = self.module.download_album(self.client(m, files), 'Exports/' + m['sessionID'], target)
            self.assertEqual(result['status'], 'COMMITTED')
            times = []
            for path, data in files.items():
                self.assertEqual((target / path).read_bytes(), data)
                times.append((target / path).stat().st_mtime)
            self.assertEqual(times[1] - times[0], 5)
            report = json.loads((target / 'transfer-manifest.json').read_text())
            self.assertEqual(report['resourcesVerified'], 2)
            self.assertEqual(len(report['filesystemAttributeChanges']), 2)
            if sys.platform == 'darwin':
                for change in report['filesystemAttributeChanges']:
                    self.assertEqual(change['creationTimeStatus'], 'SET_AND_VERIFIED')
                    self.assertAlmostEqual((target / change['path']).stat().st_birthtime,
                                           (target / change['path']).stat().st_mtime, places=3)
            progress = json.loads((target / 'transfer-progress.json').read_text())
            self.assertNotIn('filesystemAttributeChanges', progress)
            self.assertEqual(len((target / 'filesystem-attributes.jsonl').read_text().splitlines()), 2)
            with self.assertRaises(FileExistsError):
                self.module.download_album(self.client(m, files), 'Exports/' + m['sessionID'], target)
            for path, data in files.items(): self.assertEqual((target / path).read_bytes(), data)

    def test_corrupt_download_never_commits_and_keeps_failure_journal(self):
        m, files = self.fixture()
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / 'new'
            with self.assertRaises(ValueError):
                self.module.download_album(self.client(m, files, True), 'Exports/' + m['sessionID'], target)
            self.assertFalse((target / 'transfer-manifest.json').exists())
            self.assertEqual(json.loads((target / 'transfer-progress.json').read_text())['status'], 'FAILED')
            self.assertTrue(list(target.rglob('*.part')))

    def test_cancel_marker_stops_before_creating_a_local_backup(self):
        m, files = self.fixture()
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d); marker = root / 'cancel'; marker.write_text('stop')
            target = root / 'new'
            with self.assertRaisesRegex(RuntimeError, '安全停止'):
                self.module.download_album(self.client(m, files), 'Exports/' + m['sessionID'], target, marker)
            self.assertFalse(target.exists())

    @unittest.skipUnless(sys.platform == 'darwin', 'Darwin creation-time API')
    def test_creation_time_never_follows_a_symbolic_link(self):
        with tempfile.TemporaryDirectory() as d:
            original = pathlib.Path(d) / 'original'; original.write_bytes(b'untouched')
            before = original.stat().st_birthtime
            link = pathlib.Path(d) / 'link'; link.symlink_to(original)
            with self.assertRaises(OSError): self.module.set_copy_creation_time(link, 1_700_000_000_000_000_000)
            self.assertEqual(original.stat().st_birthtime, before)
            self.assertEqual(original.read_bytes(), b'untouched')

if __name__ == '__main__': unittest.main()
