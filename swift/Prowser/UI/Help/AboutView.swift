import AppKit
import SwiftUI

struct AboutView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.themeColors) private var colors

    var onShowLicense: () -> Void = {}
    var onShowCredits: () -> Void = {}

    @State private var pythonVersion = "Loading…"

    private var buildDate: String {
        AboutBuildInfo.latestPythonSourceDate(repoRoot: PythonLocator.locateRepoRoot())
    }

    var body: some View {
        VStack(spacing: 10) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
            }

            Text("Prowser")
                .font(.system(size: 18, weight: .bold))

            Text("Version: \(AboutBuildInfo.packageVersion())")
                .font(.system(size: 12))

            Text("Python Version: \(pythonVersion)")
                .font(.system(size: 12))

            Text("Build Date: \(buildDate)")
                .font(.system(size: 12))

            Text("Background jobs: \(AboutBuildInfo.backgroundJobMode())")
                .font(.system(size: 12))

            Text("A native image browser for macOS")
                .multilineTextAlignment(.center)

            Text("Built with Python and PySide6")
                .font(.system(size: 12))
                .foregroundStyle(colors.dialogMutedText)

            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com/waltz49/Prowser")!)
                Text("|").foregroundStyle(colors.dialogMutedText)
                Link("Website", destination: URL(string: "https://waltzremote.com")!)
            }

            Spacer(minLength: 8)

            DialogButtonRow(
                [
                    DialogButton("License", action: onShowLicense),
                    DialogButton("Credits", action: onShowCredits),
                    DialogButton("Close", isDefault: true, isCancel: true) {
                        appState.closeAboutDialog()
                    },
                ],
                focusDefaultOnAppear: true
            )
        }
        .padding(20)
        .frame(minWidth: 400, minHeight: 360)
        .themeDialogStyle()
        .task {
            pythonVersion = await AboutBuildInfo.pythonRuntimeVersion()
        }
    }

    private var appIcon: NSImage? {
        AppAssets.nsImage(name: "Prowser", fileExtension: "icns")
            ?? NSImage(named: NSImage.applicationIconName)
    }
}
