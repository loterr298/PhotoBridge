import unittest, tempfile, pathlib, sys, hashlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'scripts'))
import usb_probe as p

class USBChecks(unittest.TestCase):
    def test_uuid_path_rejects_traversal_and_non_probe_paths(self):
        for path in ['/DCIM/a', '../photo', 'USBProbe/Inbox/../x', 'USBProbe/Outbox/not-uuid', '/USBProbe/Inbox/0']:
            with self.assertRaises(ValueError): p.probe_directory(path)
        value = 'USBProbe/Outbox/12345678-1234-4234-8234-123456789abc'
        self.assertEqual(p.probe_directory(value), value)
    def test_generator_hash_size_and_no_clobber(self):
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / 'probe.bin'
            receipt = p.generate(target, 1024 * 1024 + 13)
            self.assertEqual(receipt['byteCount'], target.stat().st_size)
            self.assertEqual(receipt['sha256'], hashlib.sha256(target.read_bytes()).hexdigest())
            before = target.read_bytes()
            with self.assertRaises(FileExistsError): p.generate(target, 10)
            self.assertEqual(before, target.read_bytes())
    def test_partial_writes_and_stalled_writes(self):
        output = bytearray()
        def partial(data):
            count = min(3,len(data)); output.extend(data[:count]); return count
        p.write_all(partial,b'abcdefgh')
        self.assertEqual(output,b'abcdefgh')
        with self.assertRaises(IOError): p.write_all(lambda data: 0,b'abc')
        with self.assertRaises(IOError): p.write_all(lambda data: len(data)+1,b'abc')
    def test_receipt_validation_rejects_mismatch_filename_and_origin(self):
        good={'filename':'probe.bin','sha256':'a'*64,'byteCount':104857600,'origin':'iPhone'}
        p.validate_receipt(good, 'iPhone')
        for key,value in [('filename','../../original.jpg'),('sha256','bad'),('byteCount',10),('origin','Mac')]:
            with self.assertRaises(ValueError): p.validate_receipt(dict(good,**{key:value}), 'iPhone')


class DocumentsRootChecks(unittest.TestCase):
    def test_house_arrest_paths_are_beneath_documents(self):
        self.assertEqual(p.documents_path('.'), '/Documents')
        self.assertEqual(p.documents_path('USBProbe/Outbox/session/probe.bin'), '/Documents/USBProbe/Outbox/session/probe.bin')
    def test_container_escape_and_ambiguous_paths_are_rejected(self):
        for path in ['../Library','/Documents','USBProbe/../Library','USBProbe//file','USBProbe/./file','USBProbe\\file','USBProbe/\x00file','']:
            with self.assertRaises(ValueError): p.documents_path(path)

if __name__ == '__main__': unittest.main()
