#!/usr/bin/env bash
# Download and install Hugging Face models and LoRAs (dev convenience).
# Help → Downloading AI Models in the app lists models from the live catalog and offers a
# models-only bulk script (see Prowser/UI/Help/DownloadingModelsHelpHTML.swift). LoRAs below
# are not included in that bulk script.
#
# Gated FLUX repos require a Hugging Face account, accepting each model license on
# huggingface.co, and either `hf auth login` or: export HF_TOKEN=<your-token>
set -e

HF="./venv_image_browser/bin/hf"
if [ ! -x "$HF" ]; then
  HF="$(command -v hf 2>/dev/null || true)"
fi
if [ -z "$HF" ] || [ ! -x "$HF" ]; then
  echo "hf not found. Run: python3 -m pip install -U huggingface_hub" >&2
  exit 1
fi

# Full model repositories (hf cache: ~/.cache/huggingface)
MODEL_REPOS=(
  # "black-forest-labs/FLUX.1-schnell"
  "black-forest-labs/FLUX.1-dev"
  "black-forest-labs/FLUX.1-Fill-dev"
  "black-forest-labs/FLUX.2-klein-4B"
  "black-forest-labs/FLUX.2-klein-9B"
  "black-forest-labs/FLUX.2-klein-9b-kv"
  "Efficient-Large-Model/Sana_Sprint_0.6B_1024px_diffusers"
  "stablediffusionapi/anythingfurry"
  "SG161222/Realistic_Vision_V4.0_noVAE"
  "stabilityai/sd-vae-ft-mse"
)

# LoRAs: repo_id|filename → ~/.cache/image_browser/mflux_loras/<repo_with_slashes_as__>/
LORA_DOWNLOADS=(
  "Shion1124/anime-character-lora_v1.5|adapter_model.safetensors"
  "hank87/furrylora|furry_lora.safetensors"
)

lora_cache_dir() {
  local repo_id="$1"
  echo "$HOME/.cache/image_browser/mflux_loras/${repo_id//\//__}"
}

echo "=== Downloading model repositories (${#MODEL_REPOS[@]}) ==="
for REPO_ID in "${MODEL_REPOS[@]}"; do
  echo ""
  echo ">>> $REPO_ID"
  "$HF" download "$REPO_ID"
done

echo ""
echo "=== Downloading LoRAs (${#LORA_DOWNLOADS[@]}) ==="
for entry in "${LORA_DOWNLOADS[@]}"; do
  REPO_ID="${entry%%|*}"
  FILENAME="${entry#*|}"
  LOCAL_DIR="$(lora_cache_dir "$REPO_ID")"
  echo ""
  echo ">>> $REPO_ID ($FILENAME) → $LOCAL_DIR"
  mkdir -p "$LOCAL_DIR"
  "$HF" download "$REPO_ID" "$FILENAME" --local-dir "$LOCAL_DIR"
done

echo ""
echo "All downloads finished."