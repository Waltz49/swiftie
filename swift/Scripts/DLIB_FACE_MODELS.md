# dlib face models (Swift)

Native face recognition uses dlib `.dat` files downloaded on first use (consent dialog), not bundled in the `.app`.

## End-user install

1. Trigger **Search by Person (⌘P)**, **Quick Person (⌃⌘P)**, **Cache Faces (⌘=)**, or **Settings → Face Recognition → Download Face Models…**
2. Approve the download (~31 MB zip `dlib_face_models.zip`).
3. Files install to:
   `{profile}/cache/swift_native/image_recognition/dlib_models/`

Mirror offline (same as search models):

`{profile}/cache/swift_native/image_recognition/models/_mirror/dlib_face_models.zip`

Default HTTPS folder: `https://waltzremote.com/swift-prowser/search-models/v1`

## Maintainer

1. Obtain `shape_predictor_5_face_landmarks.dat`, optional `shape_predictor_68_face_landmarks.dat` (Python `encoding_model="large"`), and `dlib_face_recognition_resnet_model_v1.dat` (same as Python `face_recognition_models`).
2. Zip them as `dlib_face_models.zip` and publish beside ResNet/CLIP zips.
3. Update SHA-256 entries in `Prowser/Resources/dlib_face_models.json` when checksums are known.

## Native library

`./swift/Scripts/build_app.sh` builds dlib automatically when `Vendor/dlib-install/lib/libdlib.a` is missing (unless you pass `--skip-dlib`).

Manual build:

```bash
./swift/Scripts/build_dlib_macos.sh
cd swift && swift build -c release
```

Output: `swift/Vendor/dlib-install/` (gitignored). Requires **git** and **cmake**.
