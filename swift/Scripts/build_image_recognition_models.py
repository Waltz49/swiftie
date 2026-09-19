#!/usr/bin/env python3
"""Build Core ML search model zips for the Swift Prowser app.

Requires: torch, torchvision, transformers, coremltools (use the repo Python venv).

Outputs under swift/ModelArtifacts/:
  *.zip — install via profile …/models/_mirror/ or HTTPS base URL in Settings.

Example:
  python swift/Scripts/build_image_recognition_models.py --only resnet18
  cp swift/ModelArtifacts/*.zip ~/.swift-prowser/cache/image_recognition/models/_mirror/
"""

from __future__ import annotations

import os


def _bootstrap_tls() -> None:
    """Use certifi CA bundle (fixes python.org macOS SSL: CERTIFICATE_VERIFY_FAILED)."""
    try:
        import certifi

        ca = certifi.where()
        os.environ["SSL_CERT_FILE"] = ca
        os.environ["REQUESTS_CA_BUNDLE"] = ca
    except ImportError:
        pass


_bootstrap_tls()

import argparse
import hashlib
import json
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = REPO_ROOT / "swift" / "ModelArtifacts"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def zip_tree(tree_root: Path, zip_path: Path) -> None:
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for item in sorted(tree_root.rglob("*")):
            if item.is_file():
                zf.write(item, item.relative_to(tree_root).as_posix())


def export_resnet(arch: str, package_name: str, dest: Path) -> None:
    import torch
    import torchvision
    from torchvision.models import ResNet18_Weights, ResNet50_Weights, ResNet101_Weights
    import coremltools as ct

    spec = {
        "resnet18": (torchvision.models.resnet18, ResNet18_Weights.DEFAULT),
        "resnet50": (torchvision.models.resnet50, ResNet50_Weights.DEFAULT),
        "resnet101": (torchvision.models.resnet101, ResNet101_Weights.DEFAULT),
    }[arch]
    model = spec[0](weights=spec[1])
    model.fc = torch.nn.Identity()
    model.eval()
    example = torch.rand(1, 3, 224, 224)
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=example.shape)],
        minimum_deployment_target=ct.target.macOS13,
    )
    out = dest / package_name
    if out.exists():
        shutil.rmtree(out)
    mlmodel.save(str(out))


def export_clip_image(package_dir: Path, hf_repo: str, package_name: str) -> None:
    """Image tower: input `input` (1×3×224×224), matches Swift CLIPPreprocessor."""
    import torch
    import torch.nn as nn
    import coremltools as ct
    from transformers import CLIPModel

    clip = CLIPModel.from_pretrained(hf_repo)
    clip.eval()

    class ImageTower(nn.Module):
        def __init__(self, vision_model, visual_projection):
            super().__init__()
            self.vision_model = vision_model
            self.visual_projection = visual_projection

        def forward(self, x):
            pooled = self.vision_model(pixel_values=x).pooler_output
            return self.visual_projection(pooled)

    tower = ImageTower(clip.vision_model, clip.visual_projection)
    tower.eval()
    example = torch.rand(1, 3, 224, 224)
    traced = torch.jit.trace(tower, example, strict=False)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=example.shape)],
        minimum_deployment_target=ct.target.macOS13,
    )
    out = package_dir / package_name
    if out.exists():
        shutil.rmtree(out)
    mlmodel.save(str(out))


def export_clip_text(package_dir: Path, hf_repo: str, package_name: str) -> None:
    import torch
    import torch.nn as nn
    import coremltools as ct
    from transformers import CLIPModel

    clip = CLIPModel.from_pretrained(hf_repo)
    clip.eval()

    class TextTower(nn.Module):
        def __init__(self, text_model, text_projection):
            super().__init__()
            self.text_model = text_model
            self.text_projection = text_projection

        def forward(self, input_ids):
            out = self.text_model(input_ids=input_ids)
            return self.text_projection(out.pooler_output)

    tower = TextTower(clip.text_model, clip.text_projection)
    tower.eval()
    tokens = torch.zeros(1, 77, dtype=torch.long)
    traced = torch.jit.trace(tower, tokens, strict=False)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=tokens.shape, dtype=int)],
        minimum_deployment_target=ct.target.macOS13,
    )
    out = package_dir / package_name
    if out.exists():
        shutil.rmtree(out)
    mlmodel.save(str(out))

    _export_clip_tokenizer_files(package_dir, hf_repo)


def export_clip_b32_image(package_dir: Path) -> None:
    export_clip_image(package_dir, "openai/clip-vit-base-patch32", "CLIPViTB32Image.mlpackage")


def export_clip_b32_text(package_dir: Path) -> None:
    export_clip_text(package_dir, "openai/clip-vit-base-patch32", "CLIPViTB32Text.mlpackage")


def export_clip_l14_image(package_dir: Path) -> None:
    export_clip_image(package_dir, "openai/clip-vit-large-patch14", "CLIPViTL14Image.mlpackage")


def export_clip_l14_text(package_dir: Path) -> None:
    export_clip_text(package_dir, "openai/clip-vit-large-patch14", "CLIPViTL14Text.mlpackage")


def _export_clip_tokenizer_files(package_dir: Path, repo: str) -> None:
    """Swift CLIPTokenizer expects clip_vocab.json + clip_merges.txt (OpenAI CLIP BPE)."""
    try:
        from huggingface_hub import hf_hub_download

        vocab_path = hf_hub_download(repo_id=repo, filename="vocab.json")
        merges_path = hf_hub_download(repo_id=repo, filename="merges.txt")
        shutil.copy(vocab_path, package_dir / "clip_vocab.json")
        shutil.copy(merges_path, package_dir / "clip_merges.txt")
        return
    except Exception as exc:
        print(f"hf_hub_download tokenizer files failed ({exc}); trying tokenizer API fallback")

    from transformers import CLIPTokenizer

    tokenizer = CLIPTokenizer.from_pretrained(repo)
    vocab: dict[str, int]
    if hasattr(tokenizer, "get_vocab"):
        vocab = dict(tokenizer.get_vocab())
    elif hasattr(tokenizer, "encoder"):
        vocab = dict(tokenizer.encoder)
    else:
        raise RuntimeError("Cannot export CLIP vocab for Swift CLIPTokenizer")
    (package_dir / "clip_vocab.json").write_text(
        json.dumps(vocab, ensure_ascii=False), encoding="utf-8"
    )
    merges_lines = ["#version: 0.2"]
    if hasattr(tokenizer, "bpe_ranks"):
        merges_lines.extend(f"{a} {b}" for a, b in tokenizer.bpe_ranks.keys())
    else:
        raise RuntimeError("Cannot export CLIP merges for Swift CLIPTokenizer")
    (package_dir / "clip_merges.txt").write_text("\n".join(merges_lines) + "\n", encoding="utf-8")


def build_zip(staging_fn, zip_path: Path, skip_if_exists: bool = False) -> str:
    if skip_if_exists and zip_path.is_file() and zip_path.stat().st_size > 0:
        digest = sha256_file(zip_path)
        print(f"Skip existing {zip_path}  sha256={digest}")
        return digest
    with tempfile.TemporaryDirectory(prefix="prowser_ml_") as tmp:
        root = Path(tmp) / "bundle"
        root.mkdir()
        staging_fn(root)
        zip_tree(root, zip_path)
    digest = sha256_file(zip_path)
    print(f"Built {zip_path}  sha256={digest}")
    return digest


def _require_working_coremltools() -> None:
    import sys

    if sys.version_info >= (3, 14):
        print(
            "Error: Python 3.14 is not supported for Core ML export (coremltools native libs).",
            file=sys.stderr,
        )
        print("Use: ./swift/Scripts/setup_model_export_venv.sh", file=sys.stderr)
        sys.exit(1)


def main() -> int:
    _require_working_coremltools()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument(
        "--only",
        choices=["resnet18", "resnet50", "resnet101", "clip_b32", "clip_l14", "all"],
        default="all",
    )
    parser.add_argument(
        "--skip-existing",
        action="store_true",
        help="Reuse zip files already in --out (resume after a failed run).",
    )
    args = parser.parse_args()
    out_dir = args.out
    out_dir.mkdir(parents=True, exist_ok=True)
    snippets = []

    def want(key: str) -> bool:
        return args.only == "all" or args.only == key

    skip = args.skip_existing

    if want("resnet18"):
        z = out_dir / "resnet18_feature.zip"
        d = build_zip(
            lambda d: export_resnet("resnet18", "ResNet18Feature.mlpackage", d),
            z,
            skip_if_exists=skip,
        )
        snippets.append({"id": "resnet18_feature", "zipSha256": d})
    if want("resnet50"):
        z = out_dir / "resnet50_feature.zip"
        d = build_zip(
            lambda d: export_resnet("resnet50", "ResNet50Feature.mlpackage", d),
            z,
            skip_if_exists=skip,
        )
        snippets.append({"id": "resnet50_feature", "zipSha256": d})
    if want("resnet101"):
        z = out_dir / "resnet101_feature.zip"
        d = build_zip(
            lambda d: export_resnet("resnet101", "ResNet101Feature.mlpackage", d),
            z,
            skip_if_exists=skip,
        )
        snippets.append({"id": "resnet101_feature", "zipSha256": d})
    if want("clip_b32"):
        z = out_dir / "clip_vit_b32_image.zip"
        d = build_zip(lambda d: export_clip_b32_image(d), z, skip_if_exists=skip)
        snippets.append({"id": "clip_vit_b32_image", "zipSha256": d})
        z = out_dir / "clip_vit_b32_text.zip"
        d = build_zip(lambda d: export_clip_b32_text(d), z, skip_if_exists=skip)
        snippets.append({"id": "clip_vit_b32_text", "zipSha256": d})
    if want("clip_l14"):
        z = out_dir / "clip_vit_l14_image.zip"
        d = build_zip(lambda d: export_clip_l14_image(d), z, skip_if_exists=skip)
        snippets.append({"id": "clip_vit_l14_image", "zipSha256": d})
        z = out_dir / "clip_vit_l14_text.zip"
        d = build_zip(lambda d: export_clip_l14_text(d), z, skip_if_exists=skip)
        snippets.append({"id": "clip_vit_l14_text", "zipSha256": d})

    snippet_path = out_dir / "manifest_sha256_snippet.json"
    snippet_path.write_text(json.dumps(snippets, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {snippet_path}")
    mirror = Path.home() / ".swift-prowser/cache/image_recognition/models/_mirror"
    print(f"Install: cp {out_dir}/*.zip {mirror}/")
    print(f"Or set download base URL to: {out_dir.resolve().as_uri()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
