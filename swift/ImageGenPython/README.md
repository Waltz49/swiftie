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

`workers/model_tasks_worker.py` in this tree is a **bundle-local stub** (not synced
from the monorepo) so pipeline scripts can import `PerfTimer` without the full Qt worker.
