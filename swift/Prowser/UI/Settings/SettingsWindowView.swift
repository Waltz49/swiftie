import SwiftUI

@MainActor
struct SettingsWindowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab = .general
    @State private var dismissAction: SettingsDismissAction?

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(SettingsTab.visibleTabs(), selection: $selectedTab) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .tag(tab)
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            } detail: {
                settingsDetail(for: selectedTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            settingsFooter
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(SettingsDialogChrome.background)
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(SettingsDialogChrome.background)
        .background {
            SettingsWindowCloseMonitor(
                dismissAction: $dismissAction,
                onWindowAttached: { startSettingsSessionIfNeeded() },
                onCloseWithoutOK: {
                    rememberSettingsTab()
                    revertSettingsUnlessCommitted()
                }
            )
        }
        .persistedDialogGeometry(
            DialogGeometryKey.settings,
            defaultWidth: 920,
            defaultHeight: 680,
            minWidth: 760,
            minHeight: 520,
            sizeFallbackKey: DialogGeometryKey.settingsSizeFallback
        )
        .onAppear {
            selectedTab = appState.requestedSettingsTab
            startSettingsSessionIfNeeded()
        }
        .onChange(of: appState.settingsOpenRequestToken) { _, _ in
            selectedTab = appState.requestedSettingsTab
            startSettingsSessionIfNeeded()
        }
        .onDisappear {
            ThemeColorPanelController.shared.closeIfOpen()
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserOpenSettingsTab)) { notification in
            if let raw = notification.userInfo?["tab"] as? String,
               let tab = SettingsTab(rawValue: raw) {
                selectedTab = tab
            }
        }
    }

    private var settingsFooter: some View {
        DialogButtonRow(
            [
                DialogButton("Cancel", isCancel: true) { settingsCancel() },
                DialogButton("OK", isDefault: true) { settingsOK() },
            ],
            focusDefaultOnAppear: true
        )
    }

    private func startSettingsSessionIfNeeded() {
        guard !appState.config.isSettingsSessionActive else { return }
        dismissAction = nil
        appState.config.beginSettingsSession()
        appState.theme.beginSettingsSession()
    }

    private func rememberSettingsTab() {
        SettingsTab.rememberSessionTab(selectedTab)
    }

    private func settingsOK() {
        rememberSettingsTab()
        appState.theme.commitSettingsOK()
        appState.eventBus.emit(.settingsChanged)
        dismissAction = .committed
        dismiss()
    }

    private func settingsCancel() {
        rememberSettingsTab()
        revertSettingsUnlessCommitted()
        dismissAction = .cancelled
        dismiss()
    }

    private func revertSettingsUnlessCommitted() {
        guard dismissAction != .committed else { return }
        appState.theme.cancelSettingsSession()
        appState.eventBus.emit(.settingsChanged)
    }

    @ViewBuilder
    private func settingsDetail(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsTab()
        case .favorites:
            FavoritesSettingsTab()
        case .directories:
            DirectoriesSettingsTab()
        case .extensions:
            ExtensionsSettingsTab()
        case .destinations:
            DestinationsSettingsTab()
        case .excludes:
            ExcludesSettingsTab()
        case .theme:
            ThemeSettingsTab()
        case .maps:
            MapsEditorSettingsTab()
        case .slideshow:
            SlideshowSettingsTab()
        case .similarity:
            ModelsSearchSettingsTab()
        case .faces:
            FaceRecognitionSettingsTab()
        case .captioning:
            CaptioningSettingsTab()
        case .lora:
            LoRASettingsTab()
        case .caches:
            CacheSettingsTab()
        }
    }
}

private enum SettingsDismissAction {
    case committed
    case cancelled
}

/// Settings window lifecycle: start draft session when shown; revert on close without OK.
private struct SettingsWindowCloseMonitor: NSViewRepresentable {
    @Binding var dismissAction: SettingsDismissAction?
    let onWindowAttached: () -> Void
    let onCloseWithoutOK: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.dismissAction = dismissAction
        context.coordinator.onWindowAttached = onWindowAttached
        context.coordinator.onCloseWithoutOK = onCloseWithoutOK
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(dismissAction: dismissAction)
    }

    @MainActor
    final class Coordinator {
        var dismissAction: SettingsDismissAction?
        var onWindowAttached: (() -> Void)?
        var onCloseWithoutOK: (() -> Void)?
        private var observer: NSObjectProtocol?
        private weak var observedWindow: NSWindow?

        init(dismissAction: SettingsDismissAction?) {
            self.dismissAction = dismissAction
        }

        func attach(to view: NSView) {
            guard let window = view.window else { return }
            if window !== observedWindow {
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                observedWindow = window
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if self.dismissAction == .committed { return }
                        if self.dismissAction == .cancelled { return }
                        self.onCloseWithoutOK?()
                    }
                }
            }
            onWindowAttached?()
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
