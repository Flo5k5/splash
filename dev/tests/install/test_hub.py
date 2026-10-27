import contextlib
import fcntl
import hashlib
import io
import json
import os
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from install import hub

REPO = "owner/model"
COMMIT = "c" * 40
# The repository's files: config.json is in the Hub cache before each test.
FILES = {
    "config.json": b"{}",
    "model-1.safetensors": b"1" * 300,
    "model-2.safetensors": b"2" * 200,
}
WEIGHTS = {"model-1.safetensors", "model-2.safetensors"}
# The bytes huggingface_hub appends to a partial file at a time, here.
CHUNK = 100


def blob(name):
    return hashlib.sha256(FILES[name]).hexdigest()


class Stdout(io.StringIO):
    """stdout recording each write, and each flush as None."""

    def __init__(self):
        super().__init__()
        self.calls = []

    def write(self, text):
        self.calls.append(text)
        return super().write(text)

    def flush(self):
        self.calls.append(None)
        super().flush()


class DownloadTest(unittest.TestCase):
    """Repository.download into the Hub cache as huggingface_hub fills it:
    each blob written to a partial file of its own, then renamed. The
    partial files a killed download left, and the progress it reports."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.cache = Path(temporary.name) / "hub"
        repository = self.cache / hub.folder_name(REPO)
        self.blobs = repository / "blobs"
        self.blobs.mkdir(parents=True)
        (self.blobs / blob("config.json")).write_bytes(FILES["config.json"])
        self.locks = self.cache / ".locks" / repository.name
        self.snapshot = repository / "snapshots" / COMMIT
        self.stdout = Stdout()
        self.downloads = []
        # Called with the bytes downloaded so far after each chunk.
        self.after_chunk = lambda done: None
        for name, replacement in (
            ("huggingface_hub.constants.HF_HUB_CACHE", str(self.cache)),
            ("huggingface_hub.snapshot_download", self.snapshot_download),
            ("install.hub.PROGRESS_INTERVAL", 0.001),
        ):
            patch = mock.patch(name, replacement)
            patch.start()
            self.addCleanup(patch.stop)

    def snapshot_download(self, repo_id, *, revision, allow_patterns, max_workers):
        """Each file's blob, appended to <blob>.<random>.incomplete a chunk at
        a time, then renamed, and linked from the snapshot."""
        self.downloads.append(sorted(allow_patterns))
        done = 0
        for name in allow_patterns:
            target = self.blobs / blob(name)
            if not target.exists():
                partial = self.blobs / f"{blob(name)}.0123abcd.incomplete"
                with partial.open("wb") as file:
                    for start in range(0, len(FILES[name]), CHUNK):
                        file.write(FILES[name][start : start + CHUNK])
                        file.flush()
                        done += CHUNK
                        self.after_chunk(done)
                partial.rename(target)
            self.snapshot.mkdir(parents=True, exist_ok=True)
            (self.snapshot / name).symlink_to(target)
        return str(self.snapshot)

    @staticmethod
    def repository(listed=None):
        """REPO at COMMIT as the Hub lists it, listed giving some files'
        bytes in place of their contents'."""
        listed = listed or {}
        return hub.Repository(
            REPO,
            COMMIT,
            set(FILES),
            sizes={
                name: (listed.get(name, len(content)), blob(name))
                for name, content in FILES.items()
            },
        )

    def download(self, names=WEIGHTS, *, json_progress=True):
        with (
            mock.patch.object(hub, "json_progress", json_progress),
            contextlib.redirect_stdout(self.stdout),
        ):
            return self.repository().download(names)

    def events(self):
        return [
            json.loads(line)
            for line in self.stdout.getvalue().splitlines()
            if line.startswith("{")
        ]

    def wait_for_report(self, done):
        deadline = time.monotonic() + 10
        while done not in [event["done"] for event in self.events()]:
            self.assertLess(time.monotonic(), deadline, f"{done} was not reported")
            time.sleep(0.001)

    def test_a_download_reports_the_bytes_of_the_blobs_it_fetches(self):
        self.after_chunk = self.wait_for_report
        paths = self.download(WEIGHTS | {"config.json"})
        self.assertEqual(paths["config.json"], self.snapshot / "config.json")
        events = self.events()
        # Only the blobs the cache lacked count: 300 + 200 bytes.
        self.assertEqual(
            events[0], {"event": "download", "repo": REPO, "done": 0, "total": 500}
        )
        self.assertEqual({event["total"] for event in events}, {500})
        dones = [event["done"] for event in events]
        self.assertEqual(dones, sorted(dones))
        self.assertEqual(set(dones), {0, 100, 200, 300, 400, 500})
        self.assertEqual(dones[-1], 500)
        # Each event is one write of its whole line, flushed at once.
        for index, call in enumerate(self.stdout.calls):
            if call and call.startswith("{"):
                self.assertTrue(call.endswith("}\n"), call)
                self.assertIsNone(self.stdout.calls[index + 1])
        # Beside the line people read, unchanged.
        self.assertIn(
            f"Fetching 2 file(s), 0.00 GB, from {REPO}@{'c' * 12}; "
            "cached files are reused.\n",
            self.stdout.getvalue(),
        )

    def test_a_successful_download_reports_its_completion(self):
        # Measured too seldom to report, the download still reports its end.
        with mock.patch.object(hub, "PROGRESS_INTERVAL", 3600):
            self.download()
        self.assertEqual([event["done"] for event in self.events()], [0, 500])

    def test_progress_is_reported_only_when_asked(self):
        self.download(json_progress=False)
        self.assertEqual(self.events(), [])
        self.assertIn("Fetching 2 file(s)", self.stdout.getvalue())

    def test_a_download_of_cached_blobs_reports_nothing(self):
        self.download({"config.json"})
        self.assertEqual(self.stdout.getvalue(), "")
        self.assertEqual(self.downloads, [["config.json"]])

    def test_a_failed_download_reports_no_completion(self):
        def fail(done):
            self.wait_for_report(done)
            raise OSError("connection reset")

        self.after_chunk = fail
        threads = set(threading.enumerate())
        with self.assertRaisesRegex(OSError, "connection reset"):
            self.download()
        self.assertEqual([event["done"] for event in self.events()], [0, 100])
        # The measuring thread is stopped.
        self.assertEqual(set(threading.enumerate()), threads)

    def test_partial_files_a_killed_download_left_are_removed(self):
        killed = self.blobs / f"{blob('model-1.safetensors')}.deadbeef.incomplete"
        killed.write_bytes(b"1" * 150)
        # Of a blob this download does not fetch.
        other = self.blobs / f"{'e' * 64}.deadbeef.incomplete"
        other.write_bytes(b"e")
        self.after_chunk = lambda done: self.assertFalse(killed.exists())
        self.download()
        self.assertFalse(killed.exists())
        self.assertTrue(other.exists())

    def test_a_partial_file_whose_download_holds_its_lock_is_kept(self):
        # Another process downloading the same blob, as huggingface_hub
        # locks it.
        live = self.blobs / f"{blob('model-1.safetensors')}.feedface.incomplete"
        live.write_bytes(b"1" * 150)
        self.locks.mkdir(parents=True)
        lock = os.open(self.locks / f"{blob('model-1.safetensors')}.lock", os.O_CREAT)
        self.addCleanup(os.close, lock)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.download()
        self.assertTrue(live.exists())
        # Once that download ends, a later one removes it.
        fcntl.flock(lock, fcntl.LOCK_UN)
        for name in WEIGHTS:
            (self.blobs / blob(name)).unlink()
            (self.snapshot / name).unlink()
        self.download()
        self.assertFalse(live.exists())


if __name__ == "__main__":
    unittest.main()
