import CoreServices
import Foundation

enum LoRAFileProvenance {
    static func whereFromURLs(for path: String) -> [String] {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded) as CFURL
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url) else { return [] }
        guard let raw = MDItemCopyAttribute(item, kMDItemWhereFroms as CFString) else { return [] }
        if let list = raw as? [String] {
            return list
        }
        if let list = raw as? [Any] {
            return list.compactMap { $0 as? String }
        }
        return []
    }

    static func provenanceSuggestions(for path: String) -> (safetensorsOrigin: String?, webPageURL: String?) {
        LoRAURLClassification.provenanceSuggestions(from: whereFromURLs(for: path))
    }
}
