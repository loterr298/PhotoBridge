import hashlib, json, pathlib, sys, tempfile, unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'scripts'))
import test_album_export as export_tests


class RestoreChecks(unittest.TestCase):
    def setUp(self):
        import album_restore
        self.module = album_restore

    def fixture(self, root):
        manifest, files = export_tests.AlbumExportChecks().fixture()
        for name, data in files.items():
            path = root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
        raw = json.dumps(manifest).encode(); (root / 'album-order.json').write_bytes(raw)
        (root / 'transfer-manifest.json').write_text(json.dumps({'status': 'COMMITTED',
            'sourceManifestSHA256': hashlib.sha256(raw).hexdigest(), 'resourcesVerified': 2,
            'bytesVerified': sum(map(len, files.values()))}))
        return manifest, files

    def client(self, root, corrupt=False):
        class Client:
            def mkdir(self, path, exclusive=False):
                (root / path).mkdir(parents=True, exist_ok=not exclusive)
            def write_new(self, path, source):
                with (root / path).open('xb') as f:
                    while True:
                        data = source.read(3)
                        if not data: break
                        f.write(data)
            def read(self, path, sink, maximum=None):
                data = (root / path).read_bytes()
                if corrupt and path.endswith('.HEIC.part'): data += b'corruption'
                if maximum is not None and len(data) > maximum: raise ValueError('exceeds bound')
                for offset in range(0, len(data), 3): sink(data[offset:offset+3])
            def commit_new(self, source, destination):
                # Filesystem boundary double retains the AFC no-overwrite contract.
                if (root / destination).exists(): raise FileExistsError(destination)
                (root / source).rename(root / destination)
        return Client()

    def test_upload_preserves_every_resource_and_publishes_request_last(self):
        with tempfile.TemporaryDirectory() as d:
            base = pathlib.Path(d); backup = base / 'backup'; backup.mkdir()
            manifest, files = self.fixture(backup); remote = base / 'phone'; remote.mkdir()
            result = self.module.upload_backup(self.client(remote), backup)
            inbox = remote / result['remote']
            request = json.loads((inbox / 'restore-request.json').read_text())
            self.assertEqual(request['state'], 'USB_VERIFIED')
            self.assertEqual(request['resourceCount'], 2)
            for name, data in files.items(): self.assertEqual((inbox / name).read_bytes(), data)
            self.assertEqual(json.loads((inbox / 'album-order.json').read_text()), manifest)
            self.assertEqual(result['photosImport'], 'NOT_RUN')

    def test_corrupt_or_uncommitted_local_backup_writes_nothing_to_phone(self):
        for corrupt in [True, False]:
            with self.subTest(corrupt=corrupt), tempfile.TemporaryDirectory() as d:
                base = pathlib.Path(d); backup = base / 'backup'; backup.mkdir()
                _, files = self.fixture(backup); remote = base / 'phone'; remote.mkdir()
                if corrupt: (backup / next(iter(files))).write_bytes(b'changed original')
                else: (backup / 'transfer-manifest.json').write_text('{"status":"FAILED"}')
                with self.assertRaises(ValueError): self.module.upload_backup(self.client(remote), backup)
                self.assertEqual(list(remote.iterdir()), [])

    def test_corrupt_usb_readback_never_publishes_ready_request(self):
        with tempfile.TemporaryDirectory() as d:
            base = pathlib.Path(d); backup = base / 'backup'; backup.mkdir(); self.fixture(backup)
            remote = base / 'phone'; remote.mkdir()
            with self.assertRaises(ValueError): self.module.upload_backup(self.client(remote, True), backup)
            self.assertFalse(list(remote.rglob('restore-request.json')))
            self.assertTrue(list(remote.rglob('*.part')))

    def test_local_resource_symlink_is_rejected_before_remote_writes(self):
        with tempfile.TemporaryDirectory() as d:
            base = pathlib.Path(d); backup = base / 'backup'; backup.mkdir(); _, files = self.fixture(backup)
            path = backup / next(iter(files)); original = base / 'original'; path.rename(original); path.symlink_to(original)
            remote = base / 'phone'; remote.mkdir()
            with self.assertRaises(ValueError): self.module.upload_backup(self.client(remote), backup)
            self.assertEqual(list(remote.iterdir()), [])


if __name__ == '__main__': unittest.main()
