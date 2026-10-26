import json
import pathlib
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'scripts'))
import mac_control
import usb_probe

NONCE = '12345678-1234-4234-8234-123456789abc'
OLD = '12345678-1234-4234-8234-123456789abd'


class ConnectionChecks(unittest.TestCase):
    def test_only_matching_fresh_phone_reply_confirms_usb(self):
        self.assertTrue(hasattr(mac_control, 'heartbeat'), 'live USB handshake is missing')
        class Client:
            raw = b''
            def mkdir(self, path): pass
            def replace_connection(self, raw): self.raw = raw
        client = Client()
        with patch.object(mac_control, 'read', return_value={'kind': 'PhotoBridgeConnectionReply', 'nonce': NONCE, 'foreground': True}):
            self.assertEqual(mac_control.heartbeat(client, NONCE, OLD, wait=0)['status'], 'CONNECTED')
        self.assertEqual(json.loads(client.raw)['confirmedNonce'], OLD)
        for reply in [{'kind': 'PhotoBridgeConnectionReply', 'nonce': OLD, 'foreground': True},
                      {'kind': 'PhotoBridgeConnectionReply', 'nonce': NONCE, 'foreground': False},
                      {'kind': 'PhotoBridgeConnectionReply', 'nonce': NONCE, 'foreground': 1}]:
            with patch.object(mac_control, 'read', return_value=reply):
                self.assertNotEqual(mac_control.heartbeat(client, NONCE, None, wait=0)['status'], 'CONNECTED')
        with patch.object(mac_control, 'read', side_effect=ValueError('partial JSON')):
            self.assertEqual(mac_control.heartbeat(client, NONCE, None, wait=0)['status'], 'PHONE_NOT_READY')

    def test_heartbeat_replacement_never_opens_media_or_link_targets(self):
        self.assertTrue(hasattr(usb_probe.AFC, 'replace_connection'), 'bounded heartbeat slot is missing')
        client = usb_probe.AFC.__new__(usb_probe.AFC)
        opened = []
        client._write_file = lambda path, source, offset, **kw: opened.append((path, source.read()))
        client.list = lambda path: ['connection-request.json']
        client.info = lambda path: {'st_ifmt': 'S_IFDIR'} if path == 'Control' else {'st_ifmt': 'S_IFREG', 'st_nlink': '1'}
        raw = json.dumps({'kind': 'PhotoBridgeConnection', 'nonce': NONCE, 'confirmedNonce': None}).encode()
        client.replace_connection(raw)
        self.assertEqual(opened[0][0], 'Control/connection-request.json')
        for bad in [b'{}', b' ' * 4097, json.dumps({'kind': 'PhotoBridgeConnection', 'nonce': '../original.jpg'}).encode()]:
            with self.assertRaises(ValueError): client.replace_connection(bad)
        client.info = lambda path: {'st_ifmt': 'S_IFDIR'} if path == 'Control' else {'st_ifmt': 'S_IFLNK', 'st_nlink': '1'}
        with self.assertRaises(ValueError): client.replace_connection(raw)
        self.assertEqual(len(opened), 1)


if __name__ == '__main__': unittest.main()
