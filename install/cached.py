"""Install, without the Hub, the models the Hugging Face cache holds whole
that Splash serves: what other tools, or another Splash such as a source
checkout, downloaded there. The Mac app runs it so that it offers those models
beside the ones it downloaded:

    python install/cached.py [--models DIR]

prints, one JSON line each, {"model": ID} for each model it installed. A
repository it cannot serve installs nothing: a model of no family Splash
serves, one missing files, or no model at all, such as a draft.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import sys
from pathlib import Path

if __name__ == "__main__" and not __package__:
    # Run as a script, from the installation's install/ folder: import its
    # siblings as the install package.
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    __package__ = "install"

from . import models, paths

SUGGESTED = Path(__file__).with_name("suggested-models.tsv")


def suggested():
    """The suggested models' IDs (suggested-models.tsv), by repository."""
    by_repository = {}
    for line in SUGGESTED.read_text().splitlines():
        if line and not line.startswith("#"):
            model = line.split("\t", 1)[0]
            by_repository.setdefault(model.split(":")[0], []).append(model)
    return by_repository


def candidates(name, files, suggested_models):
    """The model IDs repository name's cached files may install as: the
    suggested ones of the repository; else each GGUF target by the variant
    upstream.select_gguf takes it by, its root files' names past the words
    they share, or its split parts' folder; else the repository itself, one
    GGUF, an MLX model, or files the installer refuses."""
    from . import upstream

    if name in suggested_models:
        return suggested_models[name]
    targets = [n for n in upstream.root_ggufs(files) if not upstream.projector_named(n)]
    folders = sorted(
        {
            n.split("/")[0]
            for n in files
            if n.count("/") == 1
            and n.endswith(".gguf")
            and not upstream.projector_named(n)
        }
    )
    ids = [f"{name}:{folder}" for folder in folders]
    if len(targets) > 1:
        parts = [Path(n).stem.split("-") for n in targets]
        shared = len(os.path.commonprefix(parts))
        ids += [f"{name}:{'-'.join(words[shared:])}" for words in parts]
    return ids or [name]


def install_cached(models_root):
    """Install each model the Hub cache holds whole that is not installed in
    models_root, without the Hub; yield the IDs installed."""
    from huggingface_hub import constants

    from . import hub, upstream

    suggested_models = suggested()
    for folder in sorted(Path(constants.HF_HUB_CACHE).glob("models--*")):
        name = folder.name.removeprefix("models--").replace("--", "/")
        try:
            repository = hub.Repository.resolve(name)
        except (models.ModelError, OSError):
            continue
        for model in candidates(name, repository.files, suggested_models):
            try:
                selection = models.Selection.of(models_root, model)
                if selection.link.exists():
                    continue
                with contextlib.redirect_stdout(io.StringIO()):
                    upstream.prepare(selection)
            except (models.ModelError, OSError):
                continue
            yield model


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--models", type=Path, default=paths.MODELS)
    args = parser.parse_args(argv)
    # Only what the cache holds: the Hub is never asked.
    os.environ["HF_HUB_OFFLINE"] = "1"
    for model in install_cached(args.models):
        print(json.dumps({"model": model}), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
