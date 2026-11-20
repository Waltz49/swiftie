import AppKit
import CoreGraphics
import Foundation

/// Session-only browse rotation/flip state (per file path). Never written to disk.
enum BrowseImageSessionTransform {
    struct State: Equatable {
        var rotationDegrees = 0
        var flipHorizontal = false
        var flipVertical = false

        var isIdentity: Bool {
            rotationDegrees == 0 && !flipHorizontal && !flipVertical
        }

        mutating func rotate(by delta: Int) {
            rotationDegrees = ((rotationDegrees + delta) % 360 + 360) % 360
        }

        mutating func toggleFlipHorizontal() {
            flipHorizontal.toggle()
        }

        mutating func toggleFlipVertical() {
            flipVertical.toggle()
        }
    }

    static let identity = State()

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Layout size after rotation (flips do not swap axes).
    static func layoutSize(for imageSize: NSSize, transform: State) -> NSSize {
        let rotation = ((transform.rotationDegrees % 360) + 360) % 360
        if rotation == 90 || rotation == 270 {
            return NSSize(width: imageSize.height, height: imageSize.width)
        }
        return imageSize
    }

    static func applyVisualTransform(to context: CGContext, transform: State) {
        if transform.flipHorizontal { context.scaleBy(x: -1, y: 1) }
        if transform.flipVertical { context.scaleBy(x: 1, y: -1) }
        if transform.rotationDegrees != 0 {
            context.rotate(by: CGFloat(transform.rotationDegrees) * .pi / 180)
        }
    }

    static func localContentRect(contentSize: NSSize) -> NSRect {
        NSRect(
            x: -contentSize.width / 2,
            y: -contentSize.height / 2,
            width: contentSize.width,
            height: contentSize.height
        )
    }
}

@MainActor
final class BrowseImageSessionTransformStore {
    private var byPath: [String: BrowseImageSessionTransform.State] = [:]

    func transform(for path: String) -> BrowseImageSessionTransform.State {
        let key = BrowseImageSessionTransform.canonicalPath(path)
        return byPath[key] ?? BrowseImageSessionTransform.identity
    }

    func mutate(path: String, _ body: (inout BrowseImageSessionTransform.State) -> Void) {
        let key = BrowseImageSessionTransform.canonicalPath(path)
        var state = byPath[key] ?? BrowseImageSessionTransform.identity
        body(&state)
        if state.isIdentity {
            byPath.removeValue(forKey: key)
        } else {
            byPath[key] = state
        }
    }

    func clear(path: String) {
        let key = BrowseImageSessionTransform.canonicalPath(path)
        byPath.removeValue(forKey: key)
    }
}