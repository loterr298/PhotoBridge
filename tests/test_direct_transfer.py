import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))


class FakeClient:
    def __init__(self):
        self.calls = []

    def mkdir(self, path):
        self.calls.append(("mkdir", path))

    def vend(self, bundle):
        self.calls.append(("vend", bundle))

    def write_new(self, path, source):
        self.calls.append(("write", path))
        while source.read(1024):
            pass

    def commit_new(self, source, destination):
        self.calls.append(("commit", source, destination))

    def close(self):
        self.calls.append(("close",))


class DirectTransferChecks(unittest.TestCase):
    def test_ordered_media_files_uses_explicit_display_order_and_ignores_sidecars(self):
        from direct_transfer import ordered_media_files

        with tempfile.TemporaryDirectory() as root:
            folder = pathlib.Path(root)
            (folder / "10.JPG").write_bytes(b"10")
            (folder / "2.HEIC").write_bytes(b"2")
            (folder / "01.png").write_bytes(b"1")
            (folder / "album-order.json").write_text("{}")
            (folder / ".hidden.jpg").write_bytes(b"hidden")
            self.assertEqual(
                [path.name for path in ordered_media_files(folder, ["10.JPG", "01.png", "2.HEIC"])],
                ["10.JPG", "01.png", "2.HEIC"],
            )

    def test_unlisted_files_follow_photo_bridge_filesystem_order_when_present(self):
        from direct_transfer import ordered_media_files

        with tempfile.TemporaryDirectory() as root:
            folder = pathlib.Path(root)
            first = folder / "IMG_9000.JPG"; second = folder / "IMG_0001.JPG"
            first.write_bytes(b"first"); second.write_bytes(b"second")
            import os
            os.utime(first, (100, 100)); os.utime(second, (105, 105))
            self.assertEqual([path.name for path in ordered_media_files(folder)],
                             ["IMG_9000.JPG", "IMG_0001.JPG"])

    def test_batch_runner_reuses_one_usb_client_for_all_items(self):
        from direct_transfer import DirectBatchRunner

        with tempfile.TemporaryDirectory() as root:
            folder = pathlib.Path(root)
            (folder / "01.jpg").write_bytes(b"one")
            (folder / "02.jpg").write_bytes(b"two")
            clients = []

            def factory():
                client = FakeClient()
                clients.append(client)
                return client

            result = DirectBatchRunner(
                source=folder,
                session="00000000-0000-0000-0000-000000000001",
                client_factory=factory,
                bundle="com.photobridge.OrderProbe",
            ).run()

            self.assertEqual(len(clients), 1)
            self.assertEqual(result["completed"], 2)
            self.assertEqual(
                [call[0] for call in clients[0].calls if call[0] == "commit"],
                ["commit", "commit"],
            )

    def test_batch_runner_commits_in_explicit_display_order(self):
        from direct_transfer import DirectBatchRunner

        with tempfile.TemporaryDirectory() as root:
            folder = pathlib.Path(root)
            (folder / "first.jpg").write_bytes(b"first")
            (folder / "second.jpg").write_bytes(b"second")
            client = FakeClient()
            result = DirectBatchRunner(
                source=folder,
                session="00000000-0000-0000-0000-000000000002",
                client_factory=lambda: client,
                bundle="com.photobridge.OrderProbe",
                ordered_names=["second.jpg", "first.jpg"],
            ).run()

            commits = [call for call in client.calls if call[0] == "commit"]
            self.assertEqual([call[2].split("/")[-1] for call in commits], ["second.jpg", "first.jpg"])
            self.assertEqual(result["completed"], 2)


if __name__ == "__main__":
    unittest.main()
