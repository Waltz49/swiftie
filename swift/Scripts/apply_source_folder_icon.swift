#!/usr/bin/env swift
import AppKit
import Foundation

func printHelp(to stream: UnsafeMutablePointer<FILE>) {
    let text = """
    apply_source_folder_icon.swift — set a custom Finder folder icon from an image.

    Used by: setup_source_preblessed.sh, create_styled_dmg.sh.

    Usage: apply_source_folder_icon.swift <folder_path> <image.heic|png>

    Options:
      -h, --help    Show this help

    """
    fputs(text, stream)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("-h") || args.contains("--help") {
    printHelp(to: stdout)
    exit(0)
}

guard args.count >= 2 else {
    printHelp(to: stderr)
    exit(1)
}

let folderPath = args[0]
let imagePath = args[1]

var isDir: ObjCBool = false
guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else {
    fputs("error: not a directory: \(folderPath)\n", stderr)
    exit(1)
}
guard FileManager.default.isReadableFile(atPath: imagePath) else {
    fputs("error: cannot read image: \(imagePath)\n", stderr)
    exit(1)
}

let imageURL = URL(fileURLWithPath: imagePath)
guard let image = NSImage(contentsOf: imageURL), image.isValid else {
    fputs("error: could not load image: \(imagePath)\n", stderr)
    exit(1)
}

let ok = NSWorkspace.shared.setIcon(image, forFile: folderPath, options: [])
if !ok {
    fputs("error: NSWorkspace.setIcon failed for \(folderPath)\n", stderr)
    exit(1)
}