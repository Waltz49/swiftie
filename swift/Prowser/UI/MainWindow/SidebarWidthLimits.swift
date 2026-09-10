import CoreGraphics

/// Sidebar width limits from Python `combined_sidebar_widget.py` and `information_sidebar.py`.
enum SidebarWidthLimits {
    static let leftMin: CGFloat = 250
    static let leftMax: CGFloat = 500
    static let rightMin: CGFloat = 250
    static let rightMax: CGFloat = 800
    static let centerMin: CGFloat = 200

    static func clampLeft(_ width: CGFloat) -> CGFloat {
        min(max(width, leftMin), leftMax)
    }

    static func clampRight(_ width: CGFloat) -> CGFloat {
        min(max(width, rightMin), rightMax)
    }
}
