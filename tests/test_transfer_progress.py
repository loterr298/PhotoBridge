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
