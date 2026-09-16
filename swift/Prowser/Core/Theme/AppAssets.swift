import AppKit
import SwiftUI

/// Bundled UI assets copied from repo-root `assets/`.
enum AppAssets {
    private static var bundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }

    static func url(name: String, fileExtension: String) -> URL? {
        bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Assets")
            ?? bundle.url(forResource: name, withExtension: fileExtension)
    }

    static func nsImage(name: String, fileExtension: String = "png") -> NSImage? {
        guard let url = url(name: name, fileExtension: fileExtension) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Dock / About / empty-state icon. Prefers bundled icns, then PNG, then the system app icon.
    static var applicationIcon: NSImage? {
        nsImage(name: "Prowser", fileExtension: "icns")
            ?? nsImage(name: "Prowser", fileExtension: "png")
            ?? NSImage(named: NSImage.applicationIconName)
    }

    static func image(name: String, fileExtension: String = "png") -> Image? {
        guard let nsImage = nsImage(name: name, fileExtension: fileExtension) else { return nil }
        return Image(nsImage: nsImage)
    }
}

struct AppAssetIconButton: View {
    let normalName: String
    let hoverName: String
    var fileExtension: String = "png"
    var size: CGFloat = 26
    var iconSize: CGFloat? = nil
    var tooltip: String = ""
    let action: () -> Void

    @State private var isHovered = false

    private var renderedIconSize: CGFloat {
        iconSize ?? max(12, size - 10)
    }

    var body: some View {
        Button(action: action) {
            let imageName = isHovered ? hoverName : normalName
            if let image = AppAssets.image(name: imageName, fileExtension: fileExtension) {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: renderedIconSize, height: renderedIconSize)
            } else {
                Image(systemName: "gearshape")
                    .frame(width: renderedIconSize, height: renderedIconSize)
            }
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.secondary.opacity(isHovered ? 0.8 : 0.45), lineWidth: 1)
        )
        .onHover { isHovered = $0 }
        .graphicButtonTooltip(text: tooltip, icon: tooltipIcon)
    }

    private var tooltipIcon: NSImage? {
        AppAssets.nsImage(name: hoverName, fileExtension: fileExtension)
            ?? AppAssets.nsImage(name: normalName, fileExtension: fileExtension)
    }
}

/// Sidebar pane toolbar icon matching Python `info_action_button_stylesheet`.
/// Small asset icon button for AppKit job strip / queue views (16–22px).
@MainActor
final class NSAssetIconButton: NSButton {
    private let normalName: String
    private let hoverName: String
    private let activeNormalName: String?
    private let activeHoverName: String?
    private let iconPixelSize: CGFloat
    private let tooltipText: String
    private let tooltipToken: UUID
    var tooltipThemeColors: ThemeColors = .dark
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    var showsActiveIcon = false {
        didSet { applyIcon() }
    }

    init(
        normalName: String,
        hoverName: String,
        activeNormalName: String? = nil,
        activeHoverName: String? = nil,
        size: CGFloat = 16,
        iconSize: CGFloat? = nil,
        tooltip: String = ""
    ) {
        self.normalName = normalName
        self.hoverName = hoverName
        self.activeNormalName = activeNormalName
        self.activeHoverName = activeHoverName
        self.iconPixelSize = iconSize ?? max(12, size - 4)
        self.tooltipText = tooltip
        self.tooltipToken = UUID()
        super.init(frame: .zero)
        bezelStyle = .shadowlessSquare
        isBordered = false
        imagePosition = .imageOnly
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        applyIcon()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyIcon()
        showGraphicTooltip()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyIcon()
        GraphicButtonTooltipPopup.shared.hide(token: tooltipToken)
    }

    private func showGraphicTooltip() {
        let tip = tooltipText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tip.isEmpty, let icon = tooltipIcon() else { return }
        GraphicButtonTooltipPopup.shared.scheduleShow(
            token: tooltipToken,
            text: tip,
            icon: icon,
            colors: tooltipThemeColors,
            anchorView: self
        )
    }

    private func applyIcon() {
        let imageName: String
        if showsActiveIcon, let activeNormalName, let activeHoverName {
            imageName = isHovered ? activeHoverName : activeNormalName
        } else {
            imageName = isHovered ? hoverName : normalName
        }
        guard let nsImage = AppAssets.nsImage(name: imageName) else {
            image = nil
            return
        }
        let sized = NSImage(size: NSSize(width: iconPixelSize, height: iconPixelSize))
        sized.lockFocus()
        nsImage.draw(
            in: NSRect(x: 0, y: 0, width: iconPixelSize, height: iconPixelSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        sized.unlockFocus()
        image = sized
    }

    private func tooltipIcon() -> NSImage? {
        let imageName: String
        if showsActiveIcon, let activeHoverName {
            imageName = activeHoverName
        } else {
            imageName = hoverName
        }
        return AppAssets.nsImage(name: imageName)
            ?? AppAssets.nsImage(name: normalName)
    }
}

struct SidebarAssetIconButton: View {
    @Environment(AppState.self) private var appState

    let normalName: String
    let hoverName: String
    var tooltip: String = ""
    var selected = false
    var enabled = true
    let action: () -> Void

    @State private var isHovered = false

    private let buttonSize: CGFloat = 26
    private let iconSize: CGFloat = 18

    var body: some View {
        let colors = appState.theme.colors
        let backgroundColor: Color = {
            if selected {
                return colors.sidebarHeaderBackground.opacity(0.9)
            }
            if isHovered {
                return colors.sidebarHeaderBackground.opacity(0.55)
            }
            return colors.sidebarHeaderBackground.opacity(0.25)
        }()

        Button(action: action) {
            let imageName = (isHovered || selected) ? hoverName : normalName
            Group {
                if let nsImage = AppAssets.nsImage(name: imageName) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: iconSize, height: iconSize)
                } else {
                    Image(systemName: "questionmark")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: buttonSize, height: buttonSize)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onHover { isHovered = $0 }
        .graphicButtonTooltip(text: tooltip, icon: tooltipIcon)
    }

    private var tooltipIcon: NSImage? {
        AppAssets.nsImage(name: hoverName) ?? AppAssets.nsImage(name: normalName)
    }
}
