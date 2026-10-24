import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'scripts'))


class TransferControlChecks(unittest.TestCase):
    def test_missing_cancel_marker_allows_work(self):
        from transfer_control import check_cancel

        with tempfile.TemporaryDirectory() as root:
            check_cancel(pathlib.Path(root) / 'cancel')

    def test_cancel_marker_stops_before_next_resource(self):
        from transfer_control import CancellationRequested, check_cancel

        with tempfile.TemporaryDirectory() as root:
            marker = pathlib.Path(root) / 'cancel'
            marker.write_text('user requested safe stop')
            with self.assertRaises(CancellationRequested):
                check_cancel(marker)


if __name__ == '__main__':
    unittest.main()
