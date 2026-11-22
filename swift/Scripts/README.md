# Swift Prowser scripts (`swift/Scripts`)

Simple overview of maintainer and dev helpers. Run most shell scripts from `swift/` unless noted.
Every executable script supports `-h` / `--help` (description, who uses it, parameters).

## App build and run

- **`build_app.sh`** — Build the Prowser `.app` bundle (release by default); optional DMG, upload, debug build, dlib, and bench CLI flags.
- **`run.sh`** — Build and launch the debug app (default via `open` for proper keyboard focus).
- **`test.sh`** — Run Swift package unit tests (`swift test`).
- **`build_dlib_macos.sh`** — Build static dlib into `Vendor/dlib-install` for native face encoding.

## DMG and distribution

- **`create_styled_dmg.sh`** — Build a styled installer DMG (background, icon layout, optional source folder).
- **`copy_swift_project_files.sh`** — Copy a minimal source tree into a DMG “source” folder (or other target).
- **`setup_source_preblessed.sh`** — One-time Finder layout for the gitignored `source_preblessed` DMG template folder.
- **`apply_source_folder_icon.swift`** — Set a custom folder icon from a HEIC/PNG image.
- **`adapt_prowser_php_for_swift.py`** — Regenerate repo `prowser.php` for Swift download links and SEO version from `Info.plist`.
- **`fda_walkthrough.sh`** — Helper for granting Full Disk Access to ad-hoc/dev `.app` builds (opens Settings, clipboard path).

## Image generation Python sync and catalog

- **`sync_imagegen_python.sh`** — Rsync image-gen Python from the monorepo root into `swift/ImageGenPython/`.
- **`generate_imagegen_catalog_snapshot.sh`** — Regenerate `ImageGenPluginCatalogSnapshot.json` from vendored plugins.
- **`diff_imagegen_catalog_snapshot.sh`** — CI-style check that Python plugins match the Swift catalog snapshot.
- **`verify_plugin_catalog_ids.sh`** — Verify `ImageGenPluginCatalog.swift` plugin IDs match the JSON snapshot.

## LoRA catalog and blobs

- **`downloadModels.sh`** — Dev convenience: download Hugging Face models and selected LoRAs via `hf`.
- **`lora_registry_backup.sh`** — Save, restore, or remove LoRA registry backups (`--save` → `~/Backups/Backup-YYYY-MM-DD.HH:MM`; `--restore` / `--remove` without `-l` pick from `~/Backups`, oldest listed first).
- **`reimport-dlds.sh`** — Restore LoRA weight files from Downloads (or paths in catalog) after cache loss (dry run by default).
- **`export_lora_defaults_for_blob.py`** — Filter `lora_catalog.json` into a portable defaults payload for shipping.
- **`pack_lorablob.sh`** — Run export + encrypt into `Prowser/Resources/Assets/lorablob`.
- **`run_lora_map.py`** — Emit JSON LoRA↔model map (used from Tools → Debug → Map LoRAs).
- **`generate_lora_metadata_pdf.py`** — One-off PDF report of LoRA metadata (maintainer utility, not used by the app).

## Search / recognition models

- **`setup_model_export_venv.sh`** — Create `venv_model_export` (Python 3.12/3.13) for Core ML export.
- **`build_image_recognition_models.py`** — Download weights and build Core ML zip artifacts under `ModelArtifacts/`.
- **`publish_search_models.sh`** — Build and optionally rsync search-model zips + manifest to a remote host.
- **`IMAGE_RECOGNITION_MODELS.md`** — Notes on Core ML model install, mirrors, and publishing.
- **`DLIB_FACE_MODELS.md`** — Notes on dlib `.dat` face models and native library build.

## Swift ↔ Python workers (stdin/stdout JSON)

- **`snapshot_job_values.py`** — Freeze image-gen job values at submit time (LoRA paths, etc.).
- **`quick_person_worker.py`** — Headless quick-person face encoding for the Swift UI.
- **`faces_settings_worker.py`** — Headless known-faces settings helpers for the Swift UI.

## Assets

- **`DmgAssets/`** — DMG background image and source-folder icon (`background.png`, `source_folder.heic`); see `DmgAssets/README.md`.