import AppKit

/// Hides the pointer after idle time over the browse shell (Python `CursorManager` in `view_manager.py`).
@MainActor
final class BrowseCursorAutoHideController {
    static let activeViewModes: Set<ViewMode> = [.browse]

    /// Python `Qt.BlankCursor` via application override — reliable over browse shell on macOS.
    static let canvasBlankCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
    }()

    private weak var hideZone: NSView?
    private var isModeActive: (() -> Bool)?
    private var overHideZone = false
    private(set) var pointerHiddenOnCanvas = false
    private var blankCursorPushed = false
    private var hideTimer: Timer?
    private var lastSignificantActivityWindowPoint: NSPoint?
    private let activityMovementThresholdSq: CGFloat = 9
    private var localMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    func sync(hideZone: NSView?, isModeActive: @escaping () -> Bool) {
        guard let hideZone, isModeActive() else {
            stop()
            return
        }
        let zoneChanged = self.hideZone !== hideZone
        if zoneChanged {
            stop()
            self.hideZone = hideZone
            self.isModeActive = isModeActive
            installEventHandling()
            showCursor()
        } else {
            self.isModeActive = isModeActive
        }
        reconcilePointerPosition()
        DispatchQueue.main.async { [weak self] in
            self?.reconcilePointerPosition()
        }
    }

    /// Pointer already over the canvas when browse starts (keyboard) or after layout — Python `underMouse()` on `start()`.
    func reconcilePointerPosition() {
        guard isModeActive?() == true, let hideZone else { return }
        guard hideZone.bounds.width > 1, hideZone.bounds.height > 1 else { return }
        hideZone.window?.acceptsMouseMovedEvents = true
        if mouseIsOverHideZone() {
            armHideTimerForPointerOverZone(resetIdleOnActivity: false)
        } else if overHideZone || blankCursorPushed {
            leaveHideZone()
        }
    }

    func noteEnteredHideZone() {
        guard isModeActive?() == true else { return }
        if blankCursorPushed || pointerHiddenOnCanvas {
            overHideZone = true
            reassertAfterCanvasContentChange()
            return
        }
        lastSignificantActivityWindowPoint = nil
        armHideTimerForPointerOverZone(resetIdleOnActivity: true)
    }

    func noteExitedHideZone() {
        guard !mouseIsOverHideZone() else { return }
        leaveHideZone()
    }

    func stop() {
        cancelHideTimer()
        overHideZone = false
        uninstallEventHandling()
        showCursor()
        hideZone = nil
        isModeActive = nil
    }

    /// Pinch and other gestures that may not surface as standard mouse events.
    func noteMouseActivity() {
        guard isModeActive?() == true else { return }
        guard hideZone?.window?.isKeyWindow == true else { return }
        if mouseIsOverHideZone() {
            armHideTimerForPointerOverZone(resetIdleOnActivity: true)
        } else if overHideZone || blankCursorPushed {
            leaveHideZone()
        }
    }

    /// Browse image redraw resets AppKit cursor rects; keep blank cursor while keyboard-advancing images.
    func reassertAfterCanvasContentChange() {
        guard pointerHiddenOnCanvas, isModeActive?() == true, mouseIsOverHideZone() else { return }
        if !blankCursorPushed {
            Self.canvasBlankCursor.push()
            blankCursorPushed = true
        }
        if let hideZone {
            hideZone.window?.invalidateCursorRects(for: hideZone)
        }
    }

    private func installEventHandling() {
        guard localMonitor == nil else { return }

        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                self.handleLocalEvent(event)
            }
            return event
        }

        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleHostWindowResignedKey(notification)
                }
            }
        )
        observers.append(
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleHostWindowBecameKey(notification)
                }
            }
        )
    }

    private func uninstallEventHandling() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func handleHostWindowResignedKey(_ notification: Notification) {
        guard let hideZone, let window = hideZone.window,
              notification.object as? NSWindow === window else { return }
        leaveHideZone()
    }

    private func handleHostWindowBecameKey(_ notification: Notification) {
        guard let hideZone, let window = hideZone.window,
              notification.object as? NSWindow === window else { return }
        reconcilePointerPosition()
    }

    private func handleLocalEvent(_ event: NSEvent) {
        guard isModeActive?() == true, let hideZone else { return }
        guard let window = hideZone.window, event.window === window else {
            if overHideZone { leaveHideZone() }
            return
        }
        if !window.isKeyWindow {
            leaveHideZone()
            return
        }
        if pointerIsOverHideZone(atWindowPoint: event.locationInWindow) {
            let significant = countsAsSignificantActivity(atWindowPoint: event.locationInWindow)
            armHideTimerForPointerOverZone(resetIdleOnActivity: significant)
        } else if overHideZone || blankCursorPushed {
            leaveHideZone()
        }
    }

    private func countsAsSignificantActivity(atWindowPoint point: NSPoint) -> Bool {
        guard let last = lastSignificantActivityWindowPoint else {
            lastSignificantActivityWindowPoint = point
            return true
        }
        let dx = point.x - last.x
        let dy = point.y - last.y
        if dx * dx + dy * dy < activityMovementThresholdSq {
            return false
        }
        lastSignificantActivityWindowPoint = point
        return true
    }

    private func mouseIsOverHideZone() -> Bool {
        guard let hideZone, let window = hideZone.window else { return false }
        return pointerIsOverHideZone(atWindowPoint: window.mouseLocationOutsideOfEventStream)
    }

    private func pointerIsOverHideZone(atWindowPoint windowPoint: NSPoint) -> Bool {
        guard let hideZone, hideZone.window != nil else { return false }
        guard hideZone.bounds.width > 1, hideZone.bounds.height > 1 else { return false }
        let point = hideZone.convert(windowPoint, from: nil)
        return hideZone.bounds.contains(point)
    }

    private func armHideTimerForPointerOverZone(resetIdleOnActivity: Bool) {
        if (blankCursorPushed || pointerHiddenOnCanvas) && resetIdleOnActivity {
            showCursor()
        }
        overHideZone = true
        let willSchedule = resetIdleOnActivity || (hideTimer == nil && !blankCursorPushed)
        if willSchedule {
            scheduleHideTimer()
        }
    }

    private func leaveHideZone() {
        overHideZone = false
        lastSignificantActivityWindowPoint = nil
        cancelHideTimer()
        showCursor()
    }

    private func scheduleHideTimer() {
        cancelHideTimer()
        let timer = Timer(
            timeInterval: TimingConstants.browseCursorHideDelaySeconds,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.performHide()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func performHide() {
        let ok = hideZone?.window?.isKeyWindow == true
            && isModeActive?() == true
            && overHideZone
            && mouseIsOverHideZone()
        hideTimer = nil
        guard ok else {
            if blankCursorPushed { showCursor() }
            return
        }
        pointerHiddenOnCanvas = true
        guard !blankCursorPushed else {
            if let hideZone { hideZone.window?.invalidateCursorRects(for: hideZone) }
            return
        }
        Self.canvasBlankCursor.push()
        blankCursorPushed = true
        if let hideZone { hideZone.window?.invalidateCursorRects(for: hideZone) }
    }

    private func showCursor() {
        pointerHiddenOnCanvas = false
        if blankCursorPushed {
            NSCursor.pop()
            blankCursorPushed = false
        }
        if let hideZone {
            hideZone.window?.invalidateCursorRects(for: hideZone)
        }
    }
}
