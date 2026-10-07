import AppKit
import Foundation

/// Cached string advance widths (port of Python `_get_overlay_font_metrics` reuse).
enum ThumbnailFontMetricsCache {
    private static var widthCache: [CacheKey: CGFloat] = [:]
    private static let maxEntries = 20_000

    private struct CacheKey: Hashable {
        var fontSize: CGFloat
        var text: String
    }

    static func advanceWidth(for text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let key = CacheKey(fontSize: font.pointSize, text: text)
        if let cached = widthCache[key] {
            return cached
        }
        ThumbnailGridPerfDiagnostics.incrementMeasureAdvanceCalls()
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        if widthCache.count >= maxEntries {
            widthCache.removeAll(keepingCapacity: true)
        }
        widthCache[key] = width
        return width
    }

    static func clear() {
        widthCache.removeAll()
    }
}
