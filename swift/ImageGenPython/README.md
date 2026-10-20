# ImageGenPython bundle

Vendored Python modules for image generation (registry bridge, diffusers/MFLUX pipeline workers).

Populated by:

```bash
./Scripts/sync_imagegen_python.sh
```

Run from the `swift/` package directory. Requires `rsync`.

Runtime: system `python3` with dependencies installed in the profile venv
(`~/.swift-prowser/venvs/imagegen` by default). Swift sets `PYTHONPATH` to this
directory and `PROWSER_PROFILE` to the active profile.

`imagegen_plugins/mflux_conditioning.py` caches MFLUX text encodes (Klein, Flux1, Z-Image) across
multi-copy jobs when prompt and model setup are unchanged.

`workers/model_tasks_worker.py` and `workers/imagegen_generate_worker.py` are **bundle-local**
(not synced from the monorepo): pipeline scripts import `PerfTimer` / cancel helpers, and
Swift starts `python -m workers.imagegen_generate_worker` for optimized generation (persistent
model retention). Sync preserves these files; use `sync_imagegen_python.sh` for
`imagegen_plugins` only.

**Settings → Image Generation → MFLUX generation backend:** `optimized` (default) uses the
persistent worker; `mflux_cli` runs `mflux-generate-*` per job.
