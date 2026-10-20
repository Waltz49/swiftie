# Prowser (Swift)

Prowser is a native macOS image browser for Apple Silicon. Browse, organize, and search images with keyboard-driven workflows, EXIF tools, similarity search, and face recognition (models download on first use).

## Install from the DMG

1. Open the **swift-prowser** installer volume.
2. Drag **prowser_swift.app** (or the app shown on the volume) into **Applications**.
3. Launch from Applications. Grant privacy permissions when macOS prompts you.

## Build and run from this folder

Requirements: macOS 14+, Xcode Command Line Tools, Swift 5.9+. Face recognition also needs **cmake** and **git** (to build bundled dlib).

```bash
./setup.sh          # once: resolve packages, build dlib if needed
./run.sh            # debug build + launch
./run.sh ~/Pictures # open a folder
./Scripts/test.sh   # unit tests (Swift Package Manager; no Xcode GUI)
```

From the `swift/` directory you can also run `swift test` directly. Optional filters: `swift test --filter QueueJobStatusBuilderTests`.

Release app bundle:

```bash
./Scripts/build_app.sh
open ~/tmp/prowser_swift.app
```

Use `./Scripts/run.sh --foreground` to see log output in Terminal. Use `./Scripts/run.sh --skip-dlib` to skip the native dlib build.

Keyboard shortcuts: see [KEYBOARD.md](KEYBOARD.md). Press **F1** or **/** in the app for in-app help.

## License

Use of this software is governed by the [LICENSE](LICENSE) file in this directory (Business Source License 1.1).
