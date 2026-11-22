#!/usr/bin/env bash
# Restore user LoRA weights: copy from source_path or ~/Downloads into
# local_path entries in the profile lora_catalog.json (after cache loss).
#
# Usage:
#   ./reimport-dlds.sh           # dry run (default)
#   ./reimport-dlds.sh --go        # copy files
#   PROFILE=~/.prowser ./reimport-dlds.sh --go
set -euo pipefail

usage() {
  cat <<EOF
$(basename "$0") — restore LoRA weight files into lora_catalog local_path entries.

Copies from each entry’s source_path or ~/Downloads when the target file is missing
(dry run by default).

Used by: command line (developer or end user) after HF/cache loss.

Usage: $(basename "$0") [options]

Environment:
  PROFILE   Profile root (default: ~/.swift-prowser)
  CATALOG   lora_catalog.json path (default: \$PROFILE/data/lora_catalog.json)

Options:
  --go        Perform copies (default is dry run only)
  -h, --help  Show this help
EOF
}

GO=0
for arg in "$@"; do
  case "$arg" in
    --go) GO=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (use --go to copy)" >&2
      exit 2
      ;;
  esac
done

PROFILE="${PROFILE:-$HOME/.swift-prowser}"
CATALOG="${CATALOG:-$PROFILE/data/lora_catalog.json}"

if [[ ! -f "$CATALOG" ]]; then
  echo "Catalog not found: $CATALOG" >&2
  exit 1
fi

export GO CATALOG
python3 << 'PY'
import json
import os
import shutil
from pathlib import Path

go = os.environ.get("GO", "0") == "1"
catalog = Path(os.environ["CATALOG"]).expanduser()
data = json.loads(catalog.read_text())
ue = data.get("user_entries") or {}
downloads = Path.home() / "Downloads"


def resolve_source(entry, dest: Path):
    sp = (entry.get("source_path") or "").strip()
    if sp and not sp.lower().startswith(("http://", "https://")):
        p = Path(sp).expanduser()
        if p.is_file():
            return p
    cand = downloads / dest.name
    if cand.is_file():
        return cand
    return None


planned: list[tuple[str, Path, Path]] = []
skipped: list[tuple[str, str]] = []

for lid, entry in sorted(ue.items()):
    lp = (entry.get("local_path") or "").strip()
    name = (entry.get("display_name") or lid).strip()
    if not lp:
        skipped.append((name, "no local_path"))
        continue
    dest = Path(lp).expanduser()
    if dest.is_file():
        skipped.append((name, "already exists"))
        continue
    src = resolve_source(entry, dest)
    if src is None:
        skipped.append((name, f"no source for {dest.name}"))
        continue
    planned.append((name, src, dest))

mode = "COPY" if go else "DRY RUN"
print(f"{mode} — catalog: {catalog}")
print(f"Would copy: {len(planned)}, skipped: {len(skipped)}")
print()

if planned:
    print("=== " + ("Copying" if go else "Would copy") + f" ({len(planned)}) ===")
    ok = 0
    for name, src, dest in planned:
        print(f"{name}")
        print(f"  {src}")
        print(f"-> {dest}")
        if go:
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest)
            ok += 1
        print()
    if go:
        print(f"Copied: {ok}")

if skipped:
    print(f"=== Skipped ({len(skipped)}) ===")
    for name, why in skipped:
        print(f"  {name}: {why}")

if not go and planned:
    print("No files changed. Re-run with --go to copy.")
PY