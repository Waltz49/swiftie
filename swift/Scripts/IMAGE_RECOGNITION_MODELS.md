# Image recognition Core ML models

The Swift app downloads Core ML packages listed in `Prowser/Resources/image_recognition_models.json`.

## Maintainer export (one-time)

1. Export torchvision ResNet (18/50/101) with the classification head removed; output a 1×N feature vector named `features` (or `input` 1×3×224×224).
2. Export CLIP ViT-B/32 and ViT-L/14 image and text towers from Hugging Face / OpenAI weights.
3. Zip each `.mlpackage` plus CLIP tokenizer files (`clip_vocab.json`, `clip_merges.txt`) for text bundles.
4. Host HTTPS zips and update `downloadURL` and `sha256` in the manifest.

## User install location

`~/.swift-prowser/cache/image_recognition/models/{model_id}/`

Remove via **Settings → Caches → Clear Image Rec**.
