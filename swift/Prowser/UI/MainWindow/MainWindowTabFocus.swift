import AppKit
import SwiftUI

enum MainWindowTabStopRole {
    case tree
    case canvas
}

/// Tab-cycle anchor (Python `tree_container` / `main_content_widget`).
@MainActor
final class MainWindowTabFocusStopView: NSView {
    var role: MainWindowTabStopRole = .canvas
    weak var appState: AppState?
    var isTabStopActive = true

    override var acceptsFirstResponder: Bool { isTabStopActive }
    override var canBecomeKeyView: Bool { isTabStopActive && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        guard isTabStopActive, let appState else { return false }
        switch role {
        case .tree:
            appState.focusFileTreeKeyboardTarget()
            appState.syncFileTreeKeyboardFocus(from: window)
        case .canvas:
            appState.focusMainCanvas()
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        let roleSnapshot = role
        let windowSnapshot = window
        let appStateSnapshot = appState
        let ok = super.resignFirstResponder()
        if roleSnapshot == .tree {
            DispatchQueue.main.async {
                appStateSnapshot?.syncFileTreeKeyboardFocus(from: windowSnapshot)
            }
        }
        return ok
    }
}

@MainActor
enum MainWindowKeyViewLoop {
    static func sync(appState: AppState) {
        guard let canvas = appState.mainWindowCanvasTabStop else { return }

        let display = SidebarPaneSplitModel.leftDisplayPaneVisibility(appState: appState)
        let leftColumnVisible = appState.effectiveLeftSidebarVisible
        let useTree = leftColumnVisible && display[0]

        appState.mainWindowTreeTabStop?.isTabStopActive = useTree

        if useTree, let leftStop = appState.mainWindowTreeTabStop, leftStop.isTabStopActive {
            leftStop.nextKeyView = canvas
            canvas.nextKeyView = leftStop
        } else {
            canvas.nextKeyView = canvas
        }
    }

    static func moveFromMainCanvas(appState: AppState) {
        appState.focusLeftSidebarTabStop()
    }
}

struct MainWindowCanvasTabStopView: NSViewRepresentable {
    @Environment(AppState.self) private var appState

    func makeNSView(context: Context) -> MainWindowTabFocusStopView {
        let view = MainWindowTabFocusStopView(frame: .zero)
        view.role = .canvas
        view.appState = appState
        appState.mainWindowCanvasTabStop = view
        MainWindowKeyViewLoop.sync(appState: appState)
        return view
    }

    func updateNSView(_ nsView: MainWindowTabFocusStopView, context: Context) {
        nsView.appState = appState
        MainWindowKeyViewLoop.sync(appState: appState)
    }
}

extension AppState {
    func focusMainCanvas() {
        switch fileData.currentViewMode {
        case .thumbnail:
            thumbnailGridHost?.claimKeyboardFocus()
        case .browse:
            if let browse = browseImageHost {
                browse.window?.makeFirstResponder(browse)
            } else {
                mainWindowCanvasTabStop?.window?.makeFirstResponder(mainWindowCanvasTabStop)
            }
        case .list:
            if let list = listViewHost {
                list.window?.makeFirstResponder(list)
            } else {
                mainWindowCanvasTabStop?.window?.makeFirstResponder(mainWindowCanvasTabStop)
            }
        case .slideshow, .slideshow2, .slideshow3:
            mainWindowCanvasTabStop?.window?.makeFirstResponder(mainWindowCanvasTabStop)
        }
    }

    func focusFileTreeKeyboardTarget() {
        if let outline = fileTreeOutlineView {
            outline.window?.makeFirstResponder(outline)
        } else {
            requestFileTreeFocus()
        }
        syncFileTreeKeyboardFocus()
    }

    func syncFileTreeKeyboardFocus(from window: NSWindow? = nil) {
        let win = window ?? fileTreeOutlineView?.window ?? mainWindowTreeTabStop?.window
        let focused = KeyboardHandlerController.fileTreeKeyboardTargetIsFocused(in: win)
        if fileTreeKeyboardFocused != focused {
            fileTreeKeyboardFocused = focused
        }
    }

    func focusLeftSidebarTabStop() {
        let display = SidebarPaneSplitModel.leftDisplayPaneVisibility(appState: self)
        let leftColumnVisible = effectiveLeftSidebarVisible
        if leftColumnVisible && display[0] {
            focusFileTreeKeyboardTarget()
        }
    }
}
