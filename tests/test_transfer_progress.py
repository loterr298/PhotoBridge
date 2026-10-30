import pathlib
import sys
import time
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'scripts'))


class TransferProgressChecks(unittest.TestCase):
    def test_snapshot_reports_real_fraction_speed_and_eta(self):
        from transfer_progress import snapshot

        value = snapshot(
            status='DOWNLOADING',
            started_monotonic=100.0,
            now_monotonic=110.0,
            resources_verified=2,
            total_resources=4,
            bytes_verified=20 * 1024 * 1024,
            total_bytes=40 * 1024 * 1024,
            current_resource='Resources/000003/0001.HEIC',
        )

        self.assertEqual(value['status'], 'DOWNLOADING')
        self.assertEqual(value['resourcesVerified'], 2)
        self.assertEqual(value['totalResources'], 4)
        self.assertEqual(value['bytesVerified'], 20 * 1024 * 1024)
        self.assertEqual(value['totalBytes'], 40 * 1024 * 1024)
        self.assertAlmostEqual(value['fraction'], 0.5)
        self.assertAlmostEqual(value['bytesPerSecond'], 2 * 1024 * 1024)
        self.assertAlmostEqual(value['etaSeconds'], 10.0)
        self.assertEqual(value['currentResource'], 'Resources/000003/0001.HEIC')
        self.assertEqual(value['elapsedSeconds'], 10.0)

    def test_photo_counts_and_percentage_wait_for_final_verification(self):
        from transfer_progress import snapshot
        args = dict(started_monotonic=0, now_monotonic=1, resources_verified=2,
                    total_resources=2, bytes_verified=10, total_bytes=10,
                    assets_verified=1, total_assets=1)
        value = snapshot(status='UPLOADING', **args)
        self.assertEqual(value['assetsVerified'], 1)  # one Live Photo, two files
        self.assertEqual(value['totalAssets'], 1)
        self.assertEqual(value['percent'], 99)
        self.assertEqual(snapshot(status='USB_VERIFIED', **args)['percent'], 100)

    def test_relay_coalesces_fast_photo_updates_and_forces_final_result(self):
        import json
        from unittest.mock import patch
        from transfer_progress import ProgressRelay
        writes = []
        class Client:
            def mkdir(self, path): pass
            def replace_progress(self, path, raw): writes.append(json.loads(raw))
        relay = ProgressRelay(Client(), '12345678-1234-4234-8234-123456789abc', 'TO_MAC')
        with patch('time.monotonic', return_value=1):
            for done in range(50_001):
                relay(dict(status='WAITING_FOR_PHOTO' if done % 2 else 'DOWNLOADING', assetsVerified=done, totalAssets=50_000))
            relay(dict(status='COMMITTED', assetsVerified=50_000, totalAssets=50_000))
        self.assertEqual(len(writes), 2)
        self.assertEqual(writes[-1]['completed'], 50_000)
        self.assertEqual(writes[-1]['phase'], 'COMMITTED')

    def test_nonfinite_observations_never_escape_as_json_numbers(self):
        import json
        from transfer_progress import snapshot
        value = snapshot(status='UPLOADING', started_monotonic=float('nan'),
                         now_monotonic=float('inf'), resources_verified=0,
                         total_resources=1, bytes_verified=1, total_bytes=10)
        json.dumps(value, allow_nan=False)
        self.assertIsNone(value['etaSeconds'])

    def test_snapshot_does_not_invent_eta_before_observing_bytes(self):
        from transfer_progress import snapshot

        value = snapshot(
            status='DOWNLOADING',
            started_monotonic=100.0,
            now_monotonic=100.0,
            resources_verified=0,
            total_resources=1,
            bytes_verified=0,
            total_bytes=10,
            current_resource='Resources/000001/0001.bin',
        )

        self.assertEqual(value['fraction'], 0.0)
        self.assertEqual(value['bytesPerSecond'], 0.0)
        self.assertIsNone(value['etaSeconds'])


if __name__ == '__main__':
    unittest.main()
