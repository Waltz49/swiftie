import Foundation

/// Python ``image_gen_submit_notice.submit_notice_text``.
enum ImageGenSubmitNotice {
    static func text(for function: String) -> String {
        switch function {
        case "create": return "Create job submitted"
        case "edit": return "Edit job submitted"
        case "expand": return "Expand job submitted"
        case "infill": return "Infill job submitted"
        default: return "Job submitted"
        }
    }
}
