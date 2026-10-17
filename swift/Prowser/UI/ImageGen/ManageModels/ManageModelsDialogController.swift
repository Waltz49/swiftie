import AppKit
import SwiftUI

/// Image > Manage models — list and per-model detail windows.
@MainActor
final class ManageModelsDialogController: NSObject, NSWindowDelegate {
    private var listWindow: NSWindow?
    private var detailWindow: NSWindow?
    private weak var appState: AppState?
    private var listRefresh = 0

    func show(appState: AppState) {
        self.appState = appState
        if let listWindow {
            listWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: listRootView(appState: appState))
        let window = NSWindow(contentViewController: host)
        window.title = "Manage models"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.minSize = NSSize(width: 480, height: 360)
        window.setContentSize(NSSize(width: 600, height: 480))
        window.isReleasedWhenClosed = false
        window.delegate = self
        listWindow = window
        DialogGeometryPersistence.apply(
            to: window,
            config: appState.config,
            key: DialogGeometryKey.manageModelsList,
            defaultSize: NSSize(width: 600, height: 480),
            minSize: NSSize(width: 480, height: 360)
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func listRootView(appState: AppState) -> some View {
        ManageModelsListView(
            entries: ImageGenModelDownloadCatalog.buildCatalog(),
            installed: { ImageGenHFModelLocality.modelIsInstalled(entry: $0) },
            onSelect: { [weak self] entry in
                self?.openDetail(entry: entry, appState: appState)
            },
            onClose: { [weak self] in
                self?.listWindow?.close()
            }
        )
        .environment(appState)
        .id(listRefresh)
    }

    private func reloadList() {
        listRefresh += 1
        guard let appState, let listWindow else { return }
        let host = NSHostingController(rootView: listRootView(appState: appState))
        listWindow.contentViewController = host
    }

    private func openDetail(entry: ImageGenModelDownloadCatalogEntry, appState: AppState) {
        if detailWindow != nil {
            detailWindow?.close()
        }
        let installed = ImageGenHFModelLocality.modelIsInstalled(entry: entry)
        let view = ManageModelsDetailView(
            entry: entry,
            installed: installed,
            onClose: { [weak self] in
                self?.detailWindow?.close()
            },
            onCatalogChanged: { [weak self] in
                self?.reloadList()
            }
        )
        .environment(appState)

        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = entry.displayName
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.minSize = NSSize(width: 440, height: installed ? 220 : 420)
        window.setContentSize(NSSize(width: 520, height: installed ? 280 : 520))
        window.isReleasedWhenClosed = false
        window.delegate = self
        detailWindow = window
        if let listWindow {
            window.setFrameOrigin(
                NSPoint(
                    x: listWindow.frame.origin.x + 40,
                    y: listWindow.frame.origin.y - 40
                )
            )
        }
        DialogGeometryPersistence.apply(
            to: window,
            config: appState.config,
            key: DialogGeometryKey.manageModelsDetail,
            defaultSize: NSSize(width: 520, height: installed ? 280 : 520),
            minSize: NSSize(width: 440, height: installed ? 220 : 420)
        )
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let appState else { return }
        if window === listWindow {
            DialogGeometryPersistence.saveFrame(
                config: appState.config,
                key: DialogGeometryKey.manageModelsList,
                frame: window.frame
            )
            listWindow = nil
            detailWindow?.close()
        } else if window === detailWindow {
            DialogGeometryPersistence.saveFrame(
                config: appState.config,
                key: DialogGeometryKey.manageModelsDetail,
                frame: window.frame
            )
            detailWindow = nil
            reloadList()
        }
    }
}
