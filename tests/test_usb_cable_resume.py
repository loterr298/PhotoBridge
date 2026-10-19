from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import device_usb_cable_resume as cable


class CableFailureClassificationChecks(unittest.TestCase):
    def test_only_transport_failure_with_io_usb_removal_qualifies(self):
        for local_failure in [True, False]:
            with self.subTest(local_failure=local_failure), tempfile.TemporaryDirectory() as directory:
                class Client:
                    def vend(self, bundle): pass
                    def close(self): pass
                    def read(self, path, sink, maximum=None):
                        sink(b'partial')
                        raise RuntimeError('AFC read: error 30')
                def download(client, remote, output):
                    output.mkdir(); part = output / 'resource.part'
                    with part.open('wb') as stream:
                        def sink(data):
                            stream.write(data)
                            if local_failure: raise RuntimeError('disk write failure')
                        client.read(remote + '/Resources/000001/0001.HEIC', sink, 100)
                calls = 0
                def present():
                    nonlocal calls
                    calls += 1
                    return calls == 1
                with patch.object(cable, 'AFC', Client), patch.object(cable, 'download_album', download), \
                        patch.object(cable, 'usb_phone_present', present), patch.object(cable.time, 'sleep'):
                    result = cable.interrupt('Exports/12345678-1234-4234-8234-123456789abc', Path(directory) / 'new')
                expected = 'PHYSICAL_INTERRUPTION_NOT_PROVEN' if local_failure else 'INTERRUPTED_AWAITING_RECONNECT'
                self.assertEqual(result['status'], expected)
                self.assertEqual(result['USBReadFailure'] is None, local_failure)


if __name__ == '__main__': unittest.main()
