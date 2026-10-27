import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from dev.tests.installer_fixtures import (
    DENSE,
    MODEL,
    PROCESSOR,
    cached_snapshot,
    fake_hub,
    mlx_target,
    selection,
)
from install import cached, upstream


def vision_target(root):
    """An MLX target whose checkpoint holds its vision tower, as the app
    serves it."""
    shards = {
        "vision_tower.blocks.0.attn.qkv.weight": "model-00001-of-00002.safetensors",
        "language_model.lm_head.weight": "model-00002-of-00002.safetensors",
    }
    mlx_target(root, DENSE)
    (root / "model.safetensors").unlink()
    (root / "model.safetensors.index.json").write_text(
        json.dumps({"weight_map": shards})
    )
    for name in set(shards.values()):
        (root / name).write_text(name)
    (root / "preprocessor_config.json").write_text(json.dumps(PROCESSOR))


def readme(root):
    root.mkdir(parents=True)
    (root / "README.md").write_text("Notes")


class CachedTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.cache = self.root / "hub"

    def install_cached(self):
        with mock.patch("huggingface_hub.constants.HF_HUB_OFFLINE", True):
            return list(cached.install_cached(self.root / "app"))

    def test_installs_what_the_cache_holds_whole_without_the_hub(self):
        """A model another Splash downloaded installs here from the cache;
        a repository of no model, or one no Splash recorded a commit of,
        installs nothing; an installed model is left as it is."""
        fake = fake_hub(self, self.cache)
        fake.publish(MODEL, "d" * 40, vision_target)
        with contextlib.redirect_stdout(io.StringIO()):
            upstream.prepare(selection(self.root / "checkout", language_only=False))
        cached_snapshot(self.cache, "someone/notes", "b" * 40, readme)
        (self.cache / "models--someone--notes/refs").mkdir()
        (self.cache / "models--someone--notes/refs/main").write_text("b" * 40)
        cached_snapshot(self.cache, "someone/unrecorded", "c" * 40, readme)
        fake.requests.clear(), fake.downloads.clear()
        self.assertEqual(self.install_cached(), [MODEL])
        self.assertEqual(self.install_cached(), [])
        self.assertEqual((fake.requests, fake.downloads), ([], []))

    def test_candidates_follow_the_installer_s_names(self):
        suggested = {"owner/listed-GGUF": ["owner/listed-GGUF:UD-Q4_K_M"]}
        self.assertEqual(
            cached.candidates("owner/listed-GGUF", {"m-UD-IQ1_S.gguf"}, suggested),
            ["owner/listed-GGUF:UD-Q4_K_M"],
        )
        self.assertEqual(
            cached.candidates(
                "owner/m-GGUF",
                {"m-UD-Q4_K_M.gguf", "m-UD-Q8_0.gguf", "mmproj-BF16.gguf"},
                suggested,
            ),
            ["owner/m-GGUF:Q4_K_M", "owner/m-GGUF:Q8_0"],
        )
        self.assertEqual(
            cached.candidates(
                "owner/m-GGUF", {"Q2_0/m-Q2_0-00001-of-00002.gguf", "README.md"}, {}
            ),
            ["owner/m-GGUF:Q2_0"],
        )
        self.assertEqual(
            cached.candidates("owner/m-GGUF", {"m-UD-Q4_K_M.gguf"}, {}),
            ["owner/m-GGUF"],
        )
        self.assertEqual(
            cached.candidates("owner/m-4bit", {"config.json", "model.safetensors"}, {}),
            ["owner/m-4bit"],
        )


if __name__ == "__main__":
    unittest.main()
