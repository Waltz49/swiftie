import AppKit
import SwiftUI

struct AboutView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.themeColors) private var colors

    var onShowLicense: () -> Void = {}
    var onShowCredits: () -> Void = {}

    var body: some View {
        VStack(spacing: 10) {
            if let icon = AppAssets.applicationIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
            }

            Text("Prowser")
                .font(.system(size: 18, weight: .bold))

            Text("Version: \(AboutBuildInfo.packageVersion())")
                .font(.system(size: 12))

            Text("A native image browser for macOS")
                .multilineTextAlignment(.center)

            Text("Build Date: \(AboutBuildInfo.buildDate())")
                .font(.system(size: 12))

            Text(profileLine)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: profileLineWidth, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Built with Swift, SwiftUI, and AppKit")
                .font(.system(size: 12))
                .foregroundStyle(colors.dialogMutedText)

            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com/waltz49/Prowser")!)
                Text("|").foregroundStyle(colors.dialogMutedText)
                Link("Website", destination: URL(string: "https://waltzremote.com")!)
            }

            DialogButtonRow(
                [
                    DialogButton("License", action: onShowLicense),
                    DialogButton("Credits", action: onShowCredits),
                    DialogButton("Close", isDefault: true, isCancel: true) {
                        appState.closeAboutDialog()
                    },
                ],
                focusDefaultOnAppear: true,
                layout: .evenlySpaced
            )
        }
        .padding(20)
        .frame(minWidth: max(400, profileLineWidth + 40))
        .fixedSize()
        .themeDialogStyle()
    }

    @MainActor
    private var profileLine: String {
        "Profile: \(appState.config.prowserHome.path)"
    }

    /// Width of the profile line, capped so a long path wraps instead of exceeding the screen.
    @MainActor
    private var profileLineWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 12)
        let measured = ceil((profileLine as NSString).size(withAttributes: [.font: font]).width)
        let screenLimit = max(360, (NSScreen.main?.visibleFrame.width ?? 1400) - 120)
        return min(measured, screenLimit)
    }
}
