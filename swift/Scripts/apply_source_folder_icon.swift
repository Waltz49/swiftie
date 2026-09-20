#!/usr/bin/env swift
import AppKit
import Foundation

let args = CommandLine.arguments.dropFirst()
guard args.count >= 2 else {
    fputs("usage: apply_source_folder_icon.swift <folder_path> <image.heic|png>\n", stderr)
    exit(1)
}

let folderPath = String(args[args.startIndex])
let imagePath = String(args[args.index(after: args.startIndex)])

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
