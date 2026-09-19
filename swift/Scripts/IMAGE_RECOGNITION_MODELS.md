# Image recognition Core ML models

The Swift app installs Core ML packages listed in `Prowser/Resources/image_recognition_models.json`.

## End-user install

The app defaults to downloading from:

`https://waltzremote.com/swift-prowser/search-models/v1`

Zip names match `downloadFile` in the manifest (e.g. `clip_vit_b32_text.zip`). On first ⌘F/⌘K the app may also fetch an updated `image_recognition_models.json` from that folder.

Override or reset the URL in **Settings → Models for Search** (trash icon restores the default).

1. **Local mirror (offline / dev)**  
   Copy zip archives into:
   `~/.swift-prowser/cache/image_recognition/models/_mirror/`  
   File names must match `downloadFile` in the manifest (e.g. `clip_vit_b32_text.zip`).

2. **Download base URL**  
   Settings → **Models for Search** → **Model download base URL**  
   - HTTPS folder that serves those zip names, or  
   - `file:///absolute/path/to/swift/ModelArtifacts`

3. **Consent dialog**  
   ⌘F / ⌘K or changing models in Settings prompts before copying/downloading.

4. **Remove**  
   Settings → Caches → **Clear Image Rec**, or delete `…/image_recognition/models/`.

## Maintainer: build zips (you create them; nothing to download pre-made)

Weights come from **torchvision** (ResNet) and **Hugging Face** (`openai/clip-vit-base-patch32`) the first time you run the exporter. Output is `swift/ModelArtifacts/*.zip`.

**Use a separate venv (Python 3.12 or 3.13).** Do not use `venv_image_browser` on Python 3.14 — `coremltools` fails with `BlobWriter not loaded`.

```bash
./swift/Scripts/setup_model_export_venv.sh
./swift/Scripts/publish_search_models.sh
```

Edit `REMOTE=` in `publish_search_models.sh` before uploading.

If torchvision/Hugging Face downloads fail with `CERTIFICATE_VERIFY_FAILED` on macOS python.org builds, re-run `setup_model_export_venv.sh` (installs `certifi`) or run **Python 3.12 → Install Certificates.command** from your framework folder. Then resume with:

`./swift/Scripts/publish_search_models.sh` (skips zips already in `ModelArtifacts/`).

Options: `--only clip_b32`, `--only clip_l14`, `--build-only`, `--upload-only`.

Manual steps:

```bash
python swift/Scripts/build_image_recognition_models.py --only clip_b32
cp swift/Prowser/Resources/image_recognition_models.json swift/ModelArtifacts/
cp swift/ModelArtifacts/*.zip ~/.swift-prowser/cache/image_recognition/models/_mirror/
```

Paste `sha256` values from `manifest_sha256_snippet.json` into the manifest when publishing (the publish script can merge them automatically).

## Optional profile manifest override

Drop a full catalog at:

`~/.swift-prowser/cache/image_recognition/image_recognition_models.json`

It replaces the bundled manifest (useful for staging HTTPS URLs without rebuilding the app).

## Export notes

- ResNet zips: torchvision ResNet with `fc` removed; input `1×3×224×224` float, output feature vector.
- CLIP ViT-B/32: separate image/text zips; text zip includes `clip_vocab.json` and `clip_merges.txt`.
- CLIP ViT-L/14: `openai/clip-vit-large-patch14`; zips `clip_vit_l14_image.zip` / `clip_vit_l14_text.zip` (768-dim joint embeddings). Build with `--only clip_l14` (large download; needs ample RAM/disk).
