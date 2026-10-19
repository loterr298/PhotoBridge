import copy, json, pathlib, sys, tempfile, unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'scripts'))
import test_album_export as export_tests
import album_export


class ResumeChecks(unittest.TestCase):
    def setUp(self):
        import album_resume
        self.module = album_resume

    def client(self, manifest, files, interrupt=False):
        class Client:
            reads = []
            def read(self, path, sink, maximum=None, offset=0):
                name = path.split('/12345678-1234-4234-8234-123456789abc/', 1)[1]
                data = json.dumps(manifest).encode() if name == 'album-order.json' else files[name]
                if name != 'album-order.json': self.reads.append((name, offset))
                if interrupt and name.startswith('Resources/000002/'):
                    sink(data[:3]); raise OSError('controlled receiver interruption')
                if maximum is not None and len(data) > maximum: raise ValueError('exceeds bound')
                for start in range(offset, len(data), 3): sink(data[start:start+3])
        return Client()

    def interrupted(self, root):
        manifest, files = export_tests.AlbumExportChecks().fixture()
        old = root / 'interrupted'; remote = 'Exports/' + manifest['sessionID']
        with self.assertRaises(OSError): album_export.download_album(self.client(manifest, files, True), remote, old)
        return manifest, files, old, remote

    def test_reuses_completed_hash_and_seeks_past_partial_without_changing_old_files(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d); m, files, old, remote = self.interrupted(root)
            before = {str(p.relative_to(old)): p.read_bytes() for p in old.rglob('*') if p.is_file()}
            client = self.client(m, files); target = root / 'resumed'
            result = self.module.resume_download(client, remote, old, target)
            self.assertEqual(result['status'], 'COMMITTED')
            self.assertEqual(result['reusedVerifiedResources'], 1)
            self.assertEqual(result['resumedPartialBytes'], 3)
            self.assertEqual(client.reads, [('Resources/000002/0001.HEIC', 3)])
            for name, data in files.items(): self.assertEqual((target / name).read_bytes(), data)
            self.assertEqual(before, {str(p.relative_to(old)): p.read_bytes() for p in old.rglob('*') if p.is_file()})

    def test_changed_manifest_refused_before_new_destination(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d); m, files, old, remote = self.interrupted(root)
            changed = copy.deepcopy(m); changed['sourceOrder']['albumName'] = 'changed'
            target = root / 'must-not-exist'
            with self.assertRaises(ValueError): self.module.resume_download(self.client(changed, files), remote, old, target)
            self.assertFalse(target.exists())

    def test_corrupt_partial_prefix_or_symlink_never_commits(self):
        for link in [False, True]:
            with self.subTest(link=link), tempfile.TemporaryDirectory() as d:
                root = pathlib.Path(d); m, files, old, remote = self.interrupted(root)
                part = old / 'Resources/000002/0001.HEIC.part'
                if link:
                    original = root / 'other'; part.rename(original); part.symlink_to(original)
                else: part.write_bytes(b'BAD')
                target = root / 'resumed'
                with self.assertRaises(ValueError): self.module.resume_download(self.client(m, files), remote, old, target)
                self.assertFalse((target / 'transfer-manifest.json').exists())

    def test_completed_backup_reuse_fetches_no_resource_over_usb(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d); m, files = export_tests.AlbumExportChecks().fixture(); remote = 'Exports/' + m['sessionID']
            old = root / 'complete'; album_export.download_album(self.client(m, files), remote, old)
            client = self.client(m, files)
            result = self.module.resume_download(client, remote, old, root / 'new-copy')
            self.assertEqual(result['reusedVerifiedResources'], 2)
            self.assertEqual(result['usbResourceBytesRead'], 0)
            self.assertEqual(client.reads, [])

    def test_destination_inside_previous_or_its_symlink_alias_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d); m, files, old, remote = self.interrupted(root)
            alias = root / 'alias'; alias.symlink_to(old, target_is_directory=True)
            for destination in [old / 'nested-result', alias / 'nested-result']:
                with self.assertRaises(ValueError): self.module.resume_download(self.client(m, files), remote, old, destination)
            self.assertFalse((old / 'nested-result').exists())


if __name__ == '__main__': unittest.main()
