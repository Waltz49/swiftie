import AppKit
import SwiftUI

enum MainWindowTabStopRole {
    case tree
    case chat
    case canvas
}

/// Tab-cycle anchor (Python `tree_container` / `chat_container` / `main_content_widget`).
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
        case .chat:
            appState.focusChatPrompt()
        case .canvas:
            appState.focusMainCanvas()
        }
        return true
    }
}

@MainActor
enum MainWindowKeyViewLoop {
    static func sync(appState: AppState) {
        guard let canvas = appState.mainWindowCanvasTabStop else { return }

        let display = SidebarPaneSplitModel.leftDisplayPaneVisibility(appState: appState)
        let leftColumnVisible = appState.effectiveLeftSidebarVisible
        let useChat = leftColumnVisible && display[2]
        let useTree = leftColumnVisible && display[0] && !useChat

        appState.mainWindowTreeTabStop?.isTabStopActive = useTree
        appState.mainWindowChatTabStop?.isTabStopActive = useChat

        let leftStop: MainWindowTabFocusStopView?
        if useChat {
            leftStop = appState.mainWindowChatTabStop
        } else if useTree {
            leftStop = appState.mainWindowTreeTabStop
        } else {
            leftStop = nil
        }

        if let leftStop, leftStop.isTabStopActive {
            leftStop.nextKeyView = canvas
            canvas.nextKeyView = leftStop
        } else {
            canvas.nextKeyView = canvas
        }
    }

    static func moveFromChatPrompt(forward: Bool, appState: AppState) {
        if forward {
            appState.focusMainCanvas()
            return
        }
        let display = SidebarPaneSplitModel.leftDisplayPaneVisibility(appState: appState)
        if display[2] {
            appState.focusChatPrompt()
        } else {
            appState.focusFileTreeKeyboardTarget()
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

struct MainWindowChatTabStopView: NSViewRepresentable {
    @Environment(AppState.self) private var appState

    func makeNSView(context: Context) -> MainWindowTabFocusStopView {
        let view = MainWindowTabFocusStopView(frame: .zero)
        view.role = .chat
        view.appState = appState
        appState.mainWindowChatTabStop = view
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
    }

    func focusChatPrompt() {
        if let textView = chatPromptTextView, textView.isEditable {
            textView.window?.makeFirstResponder(textView)
        } else if let stop = mainWindowChatTabStop {
            stop.window?.makeFirstResponder(stop)
        }
    }

    func focusLeftSidebarTabStop() {
        let display = SidebarPaneSplitModel.leftDisplayPaneVisibility(appState: self)
        let leftColumnVisible = effectiveLeftSidebarVisible
        let useChat = leftColumnVisible && display[2]
        let useTree = leftColumnVisible && display[0] && !useChat
        if useChat {
            focusChatPrompt()
        } else if useTree {
            focusFileTreeKeyboardTarget()
        }
    }
}
