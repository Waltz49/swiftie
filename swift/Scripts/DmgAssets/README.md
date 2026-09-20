# DMG installer assets

| File | Purpose |
|------|---------|
| `background.png` | Finder background for the installer volume and the `source` folder (640×480) |
| `source_folder.heic` | Applied to the `source` folder icon when `Scripts/source_preblessed` is absent |

To refresh from the Python reference tree:

```bash
cp ~/dev/testchat/image_browser/background.png .
cp ~/dev/testchat/image_browser/source_folder.heic .
```

Optional one-time template (preserves custom folder icon in gitignored `Scripts/source_preblessed/`):

```bash
./Scripts/setup_source_preblessed.sh
```
