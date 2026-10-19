import contextlib
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import test_album_restore as restore_tests


class UploadContinuationChecks(unittest.TestCase):
    def setUp(self):
        import upload_resume
        self.module = upload_resume

    def setup_files(self, root):
        source = root / 'source'; source.mkdir()
        manifest, files = restore_tests.RestoreChecks().fixture(source)
        phone = root / 'phone'; phone.mkdir(); writes = []; append_offsets = []
        class Client:
            interrupted = True
            def mkdir(self, path, exclusive=False): (phone / path).mkdir(parents=True, exist_ok=not exclusive)
            def list(self, path): return [p.name for p in (phone / path).iterdir()]
            def info(self, path):
                p = phone / path; st = p.lstat()
                return dict(st_ifmt='S_IFLNK' if p.is_symlink() else 'S_IFDIR' if p.is_dir() else 'S_IFREG',
                    st_size=str(st.st_size), st_nlink=str(st.st_nlink))
            @contextlib.contextmanager
            def locked_file(self, path): yield
            def read(self, path, sink, maximum=None):
                data = (phone / path).read_bytes()
                if maximum is not None and len(data) > maximum: raise ValueError('exceeds bound')
                for i in range(0, len(data), 3): sink(data[i:i+3])
            def write_new(self, path, source):
                writes.append(path)
                with (phone / path).open('xb') as f:
                    if self.interrupted and path.endswith('000002/0001.HEIC.part'):
                        f.write(source.read(5)); raise RuntimeError('CONTROLLED_WRITER_INTERRUPTION')
                    f.write(source.read())
            def append_existing(self, path, source, offset):
                append_offsets.append(offset); writes.append(path)
                with (phone / path).open('ab') as f: f.write(source.read())
            def commit_new(self, part, final):
                if (phone / final).exists(): raise FileExistsError(final)
                (phone / part).rename(phone / final)
        return source, phone, manifest, files, Client(), writes, append_offsets

    def interrupted(self, root):
        source, phone, m, files, client, writes, offsets = self.setup_files(root)
        with self.assertRaisesRegex(RuntimeError, 'CONTROLLED_WRITER_INTERRUPTION'):
            self.module.upload(client, source)
        journals = list((source / 'restore-uploads').glob('*.json')); self.assertEqual(len(journals), 1)
        client.interrupted = False
        return source, phone, m, files, client, writes, offsets, journals[0]

    def test_complete_files_are_not_rewritten_and_partial_uses_exact_offset(self):
        with tempfile.TemporaryDirectory() as d:
            source, phone, m, files, c, writes, offsets, journal = self.interrupted(Path(d))
            state = json.loads(journal.read_text()); inbox = phone / state['remote']
            first = inbox / next(iter(files)); before = (first.read_bytes(), first.stat().st_mtime_ns)
            old_journal = journal.read_bytes(); writes.clear()
            result = self.module.upload(c, source, journal)
            self.assertEqual(result['state'], 'USB_VERIFIED')
            self.assertEqual(result['reusedVerifiedResources'], 1); self.assertEqual(offsets, [5])
            self.assertEqual(result['resumedPartialBytes'], 5)
            self.assertEqual(result['usbResourceBytesWritten'], len(list(files.values())[1]) - 5)
            self.assertEqual((first.read_bytes(), first.stat().st_mtime_ns), before)
            self.assertEqual(journal.read_bytes(), old_journal)
            self.assertTrue(writes[-1].endswith('restore-request.json.part'))
            for name, data in files.items(): self.assertEqual((inbox / name).read_bytes(), data)

    def test_unsafe_or_published_sessions_are_refused_before_resource_writes(self):
        for fault in ['source', 'owner', 'prefix', 'oversize', 'symlink', 'ready', 'started', 'lock']:
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as d:
                source, phone, m, files, c, writes, offsets, journal = self.interrupted(Path(d))
                state = json.loads(journal.read_text()); inbox = phone / state['remote']
                part = inbox / (list(files)[1] + '.part')
                if fault == 'source': (source / next(iter(files))).write_bytes(b'changed original')
                if fault == 'owner': (inbox / 'upload-owner.json').write_text('{}')
                if fault == 'prefix': part.write_bytes(b'wrong')
                if fault == 'oversize': part.write_bytes(b'X' * 1000)
                if fault == 'symlink':
                    saved = Path(d) / 'old'; part.rename(saved); part.symlink_to(saved)
                if fault == 'ready': (inbox / 'restore-request.json').write_text('{}')
                if fault == 'started': (inbox / 'restore-started.json').write_text('{}')
                if fault == 'lock':
                    @contextlib.contextmanager
                    def locked(path): raise RuntimeError('lock busy'); yield
                    c.locked_file = locked
                writes.clear()
                with self.assertRaises((ValueError, RuntimeError)): self.module.upload(c, source, journal)
                self.assertEqual(writes, []); self.assertEqual(offsets, [])

    def test_fresh_upload_refuses_symlinked_inbox_or_session_before_writes(self):
        for fault in ['inbox', 'session']:
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as d:
                source, phone, _, _, c, writes, offsets = self.setup_files(Path(d))
                outside = Path(d) / 'outside'; outside.mkdir()
                if fault == 'inbox': (phone / 'RestoreInbox').symlink_to(outside, target_is_directory=True)
                else:
                    original = c.mkdir
                    def mkdir(path, exclusive=False):
                        if path.startswith('RestoreInbox/'):
                            (phone / path).symlink_to(outside, target_is_directory=True)
                        else: original(path, exclusive)
                    c.mkdir = mkdir
                with self.assertRaisesRegex(ValueError, 'nonregular'):
                    self.module.upload(c, source)
                self.assertEqual(writes, []); self.assertEqual(offsets, [])
                self.assertEqual(list(outside.iterdir()), [])


if __name__ == '__main__': unittest.main()
