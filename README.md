# Prowser

**Prowser** is a fast, keyboard-friendly image browser for Mac. Open a folder and scroll through photos in a grid or list, view them fullscreen, and manage files without leaving the app—move, copy, rename, send to Trash, and undo when you need to.


It is built for **Apple Silicon Macs** running **macOS Sonoma (14) or later**.

Completely **optional** AI features including captioning, search, and generation are available. 

## What you can do

- **Browse** large folders smoothly, with thumbnails and quick preview
- **Organize** files with drag-and-drop, batch operations, and favorites
- **View** EXIF and metadata, run slideshows, and send an image to an external editor
- **Search** in powerful ways—find similar images, spot duplicates, search by description, or match faces (these features download helper models the first time you use them; later runs are much faster)
- **Customize** appearance with light, dark, and saved themes
- **Optional extras** in the full build—local image generation tools, a chat pane, and integrations with local AI tools if you set them up in Settings

Press **F1** or **/** inside the app for built-in help. For a full shortcut list, see [swift/KEYBOARD.md](swift/KEYBOARD.md).

## Download

Get the latest installer from **[waltzremote.com](https://waltzremote.com/)**.

1. Open the download (DMG).
2. Drag **Prowser** into **Applications**.
3. Open it from Applications. If macOS asks for access to your photos or folders, allow it so the app can show your images (you may need to quit and open the app again after granting access).

Python 3.13 or later is required for the optional AI features. [LM Studio](https://lmstudio.ai/download) is required for AI Text Generation (captioning, automatic prompt generation).

## First-time notes

Some advanced features need a one-time download of AI models or, for generation, extra setup in **Settings**. That can take a while on a slow connection. A free [Hugging Face](https://huggingface.co/) account may be required for some downloads.

## For developers

Source code and build instructions live under [`swift/`](swift/). See [swift/README.md](swift/README.md).

## License

Prowser is offered under the [Business Source License 1.1](swift/LICENSE). Third-party components are credited in the app under **About**.