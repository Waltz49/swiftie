import AppKit
import SwiftUI

/// Saved values used to prime the rename dialog (Python `settings.get('rename_*')`).
struct RenamePrefixDialogRequest: Identifiable {
    let id = UUID()
    var savedPrefix: String
    var savedIncrementLength: Int
    var savedStartingNumber: Int
    var savedSortMode: RenamePrefixPlanner.SortMode
    var savedDateChangeMode: RenamePrefixPlanner.DateChangeMode
    var savedOrderDirection: RenamePrefixPlanner.OrderDirection
}

private enum RenamePrefixRadioGroup: CaseIterable {
    case renamingOrder
    case dateChanging
    case sequenceDirection
}

/// Tab order mirrors Python `QWidget.setTabOrder` in `_show_rename_prefix_dialog`.
private enum RenamePrefixTabField: Hashable {
    case prefix
    case incrementLength
    case startingNumber
    case radioDate
    case radioOrder
    case radioNoChange
    case radioOldest
    case radioNewest
    case radioTop
    case radioBottom
    case defaults
    case cancel
    case ok
}

/// Port of `FileOperationsManager._show_rename_prefix_dialog` ("Rename with Custom Prefix").
@MainActor
struct RenamePrefixSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.themeColors) private var colors

    let request: RenamePrefixDialogRequest

    @State private var prefixText: String
    @State private var incrementLength: Int
    @State private var startingNumber: Int
    @State private var sortMode: RenamePrefixPlanner.SortMode
    @State private var dateChangeMode: RenamePrefixPlanner.DateChangeMode
    @State private var orderDirection: RenamePrefixPlanner.OrderDirection
    @State private var finished = false

    @FocusState private var focus: RenamePrefixTabField?

    @State private var keyboardRadioGroup: RenamePrefixRadioGroup = .renamingOrder
    @State private var keyboardRadioIndex = 0

    private static let defaultPrefix = "image-%d"

    init(request: RenamePrefixDialogRequest) {
        self.request = request
        _prefixText = State(initialValue: request.savedPrefix)
        _incrementLength = State(initialValue: min(6, max(3, request.savedIncrementLength)))
        let maxStarting = Self.maxStarting(for: request.savedIncrementLength)
        _startingNumber = State(initialValue: max(0, min(request.savedStartingNumber, maxStarting)))
        _sortMode = State(initialValue: request.savedSortMode)
        _dateChangeMode = State(initialValue: request.savedDateChangeMode)
        _orderDirection = State(initialValue: request.savedOrderDirection)
    }

    private static func maxStarting(for digits: Int) -> Int {
        Int(pow(10.0, Double(digits))) - 1
    }

    private var maxStartingNumber: Int { Self.maxStarting(for: incrementLength) }
    private var isDateMode: Bool { sortMode == .date }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename with Custom Prefix")
                .font(.headline)

            formSection

            HStack(alignment: .top, spacing: 18) {
                renamingOrderBox
                dateChangingBox
                sequenceDirectionBox
                Spacer(minLength: 0)
            }

            buttonRow
        }
        .padding(20)
        .frame(minWidth: 520)
        .themeDialogStyle()
        .persistedDialogGeometry(
            DialogGeometryKey.renamePrefix,
            defaultWidth: 560,
            defaultHeight: 330,
            minWidth: 520,
            minHeight: 300
        )
        .onExitCommand { finish(nil) }
        .background {
            // Escape == Cancel regardless of which control has focus (Cancel itself owns Return).
            Button("") { finish(nil) }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .background {
            RenamePrefixKeyRoutingView(
                isPresented: { appState.renamePrefixDialog != nil },
                onTab: moveTabFocus,
                onArrow: moveArrowFocus
            )
        }
        .onAppear {
            syncKeyboardRadioFocus()
            // Python: `cancel_button.setFocus()` — default focus is always Cancel.
            DispatchQueue.main.async { focus = .cancel }
        }
        .onChange(of: incrementLength) { _, _ in
            // Python `update_starting_max`
            if startingNumber > maxStartingNumber {
                startingNumber = maxStartingNumber
            }
        }
        .onDisappear {
            // Closing via the window control counts as Cancel.
            if !finished {
                finished = true
                appState.renamePrefixService.dialogFinished(nil)
            }
        }
    }

    // MARK: - Form (prefix / digits / starting number)

    private var formSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow(alignment: .top) {
                Text("Prefix:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {
                        TextField("", text: $prefixText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                            .focused($focus, equals: RenamePrefixTabField.prefix)
                        resetPrefixButton
                    }
                    Text("Add %d for directory name. Example: 'image-%d'")
                        .font(.system(size: 11))
                        .foregroundStyle(colors.dialogMutedText)
                        .padding(4)
                }
            }
            GridRow {
                Text("Sequence digits (3-6):")
                    .gridColumnAlignment(.trailing)
                HStack {
                    spinBox(value: $incrementLength, range: 3...6, field: .incrementLength)
                    Spacer()
                }
            }
            GridRow {
                Text("Starting number:")
                    .gridColumnAlignment(.trailing)
                HStack {
                    spinBox(value: $startingNumber, range: 0...maxStartingNumber, field: .startingNumber)
                    Spacer()
                }
            }
        }
    }

    /// Trash-icon reset (same pattern as other reset controls; tooltip "Reset to 'image-%d'").
    private var resetPrefixButton: some View {
        AppAssetIconButton(
            normalName: "trash_icon",
            hoverName: "trash_icon_hover",
            size: 22,
            iconSize: 14,
            tooltip: "Reset to '\(Self.defaultPrefix)'",
            action: { prefixText = Self.defaultPrefix }
        )
        .focusable(false)
    }

    /// QSpinBox equivalent: right-aligned numeric field (80px) + stepper.
    private func spinBox(value: Binding<Int>, range: ClosedRange<Int>, field: RenamePrefixTabField) -> some View {
        HStack(spacing: 2) {
            TextField(
                "",
                value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) }
                ),
                format: .number
            )
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 80)
            .focused($focus, equals: field)
            Stepper("", value: value, in: range)
                .labelsHidden()
                .focusable(false)
        }
    }

    // MARK: - Group boxes

    private var renamingOrderBox: some View {
        radioGroupBox(title: "Renaming order:", enabled: true, spacing: 12) {
            radio(
                "Sort by Date\n(oldest becomes 1)",
                selected: sortMode == .date,
                enabled: true,
                group: .renamingOrder,
                index: 0,
                tabField: .radioDate
            ) {
                sortMode = .date
            }
            radio(
                "Sort by Current Order",
                selected: sortMode == .order,
                enabled: true,
                group: .renamingOrder,
                index: 1,
                tabField: .radioOrder
            ) {
                sortMode = .order
            }
        }
    }

    private var dateChangingBox: some View {
        radioGroupBox(title: "Date changing:", enabled: !isDateMode, spacing: 13) {
            radio(
                "No change",
                selected: dateChangeMode == .none,
                enabled: !isDateMode,
                group: .dateChanging,
                index: 0,
                tabField: .radioNoChange
            ) {
                dateChangeMode = .none
            }
            radio(
                "Top becomes oldest",
                selected: dateChangeMode == .oldest,
                enabled: !isDateMode,
                group: .dateChanging,
                index: 1,
                tabField: .radioOldest
            ) {
                dateChangeMode = .oldest
            }
            radio(
                "Top becomes newest",
                selected: dateChangeMode == .newest,
                enabled: !isDateMode,
                group: .dateChanging,
                index: 2,
                tabField: .radioNewest
            ) {
                dateChangeMode = .newest
            }
        }
    }

    private var sequenceDirectionBox: some View {
        radioGroupBox(title: "Sequence direction:", enabled: !isDateMode, spacing: 13) {
            radio(
                "Top becomes 1",
                selected: orderDirection == .top,
                enabled: !isDateMode,
                group: .sequenceDirection,
                index: 0,
                tabField: .radioTop
            ) {
                orderDirection = .top
            }
            radio(
                "Bottom becomes 1",
                selected: orderDirection == .bottom,
                enabled: !isDateMode,
                group: .sequenceDirection,
                index: 1,
                tabField: .radioBottom
            ) {
                orderDirection = .bottom
            }
        }
    }

    private func radioGroupBox<Content: View>(
        title: String,
        enabled: Bool,
        spacing: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(title)
                .foregroundStyle(enabled ? colors.dialogText : colors.dialogMutedText)
            content()
        }
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 18, trailing: 10))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(colors.dialogBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(enabled ? colors.defaultBorder : colors.dialogMutedText, lineWidth: 1.5)
        )
    }

    private func radio(
        _ title: String,
        selected: Bool,
        enabled: Bool,
        group: RenamePrefixRadioGroup,
        index: Int,
        tabField: RenamePrefixTabField,
        action: @escaping () -> Void
    ) -> some View {
        let keyboardFocused = focus == tabField
        return Button {
            keyboardRadioGroup = group
            keyboardRadioIndex = index
            focus = tabField
            action()
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(
                        !enabled ? colors.dialogMutedText : (selected ? colors.currentImageBorder : colors.dialogText)
                    )
                Text(title)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(enabled ? colors.dialogText : colors.dialogMutedText)
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(keyboardFocused ? colors.currentImageBorder : .clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(enabled)
        .focused($focus, equals: tabField)
        .disabled(!enabled)
    }

    private func syncKeyboardRadioFocus() {
        keyboardRadioGroup = .renamingOrder
        keyboardRadioIndex = sortMode == .date ? 0 : 1
    }

    private func enabledTabFields() -> [RenamePrefixTabField] {
        var fields: [RenamePrefixTabField] = [
            .prefix, .incrementLength, .startingNumber, .radioDate, .radioOrder,
        ]
        if !isDateMode {
            fields += [.radioNoChange, .radioOldest, .radioNewest, .radioTop, .radioBottom]
        }
        fields += [.defaults, .cancel, .ok]
        return fields
    }

    private func moveTabFocus(forward: Bool) {
        let fields = enabledTabFields()
        guard !fields.isEmpty else { return }
        let current = focus ?? .cancel
        let nextIndex: Int
        if let index = fields.firstIndex(of: current) {
            nextIndex = forward
                ? (index + 1) % fields.count
                : (index - 1 + fields.count) % fields.count
        } else {
            nextIndex = forward ? 0 : fields.count - 1
        }
        let next = fields[nextIndex]
        focus = next
        syncKeyboardRadioFromTabField(next)
    }

    private func tabField(for group: RenamePrefixRadioGroup, index: Int) -> RenamePrefixTabField? {
        switch group {
        case .renamingOrder:
            return index == 0 ? .radioDate : .radioOrder
        case .dateChanging:
            switch index {
            case 0: return .radioNoChange
            case 1: return .radioOldest
            default: return .radioNewest
            }
        case .sequenceDirection:
            return index == 0 ? .radioTop : .radioBottom
        }
    }

    private func syncKeyboardRadioFromTabField(_ field: RenamePrefixTabField) {
        guard let (group, index) = radioGroupAndIndex(for: field) else { return }
        keyboardRadioGroup = group
        keyboardRadioIndex = index
    }

    private static let buttonFields: [RenamePrefixTabField] = [.defaults, .cancel, .ok]

    private func moveArrowFocus(_ direction: RenamePrefixArrowDirection) {
        let current = focus ?? .cancel

        if Self.buttonFields.contains(current) {
            guard let index = Self.buttonFields.firstIndex(of: current) else { return }
            switch direction {
            case .left:
                focus = Self.buttonFields[(index - 1 + Self.buttonFields.count) % Self.buttonFields.count]
            case .right:
                focus = Self.buttonFields[(index + 1) % Self.buttonFields.count]
            case .up:
                focus = lastFieldBeforeButtons()
                syncKeyboardRadioFromTabField(focus ?? .cancel)
            case .down:
                break
            }
            return
        }

        if isRadioField(current) {
            switch direction {
            case .left, .right:
                moveRadioGroup(from: current, direction: direction)
            case .up, .down:
                moveRadioWithinGroup(from: current, direction: direction)
            }
            return
        }

        let fields = enabledTabFields()
        guard let index = fields.firstIndex(of: current) else { return }
        switch direction {
        case .down:
            guard index + 1 < fields.count else { return }
            let next = fields[index + 1]
            focus = next
            syncKeyboardRadioFromTabField(next)
        case .up:
            guard index > 0 else { return }
            let next = fields[index - 1]
            focus = next
            syncKeyboardRadioFromTabField(next)
        case .left, .right:
            break
        }
    }

    private func moveRadioGroup(from current: RenamePrefixTabField, direction: RenamePrefixArrowDirection) {
        guard let (group, index) = radioGroupAndIndex(for: current) else { return }
        let groups = enabledRadioGroups()
        guard let groupPos = groups.firstIndex(of: group) else { return }
        let delta = direction == .right ? 1 : -1
        let newGroup = groups[(groupPos + delta + groups.count) % groups.count]
        let newIndex = min(index, optionCount(for: newGroup) - 1)
        applyRadioSelection(group: newGroup, index: newIndex)
    }

    private func moveRadioWithinGroup(from current: RenamePrefixTabField, direction: RenamePrefixArrowDirection) {
        guard let (group, index) = radioGroupAndIndex(for: current) else { return }
        if direction == .down, isLastRadioField(current) {
            focus = .defaults
            return
        }
        let count = optionCount(for: group)
        let delta = direction == .up ? -1 : 1
        let newIndex = (index + delta + count) % count
        applyRadioSelection(group: group, index: newIndex)
    }

    private func applyRadioSelection(group: RenamePrefixRadioGroup, index: Int) {
        keyboardRadioGroup = group
        keyboardRadioIndex = index
        switch group {
        case .renamingOrder:
            sortMode = index == 0 ? .date : .order
        case .dateChanging:
            switch index {
            case 0: dateChangeMode = .none
            case 1: dateChangeMode = .oldest
            default: dateChangeMode = .newest
            }
        case .sequenceDirection:
            orderDirection = index == 0 ? .top : .bottom
        }
        if let field = tabField(for: group, index: index) {
            focus = field
        }
    }

    private func enabledRadioGroups() -> [RenamePrefixRadioGroup] {
        isDateMode ? [.renamingOrder] : RenamePrefixRadioGroup.allCases
    }

    private func optionCount(for group: RenamePrefixRadioGroup) -> Int {
        switch group {
        case .renamingOrder: return 2
        case .dateChanging: return 3
        case .sequenceDirection: return 2
        }
    }

    private func isRadioField(_ field: RenamePrefixTabField) -> Bool {
        radioGroupAndIndex(for: field) != nil
    }

    private func radioGroupAndIndex(for field: RenamePrefixTabField) -> (RenamePrefixRadioGroup, Int)? {
        switch field {
        case .radioDate: return (.renamingOrder, 0)
        case .radioOrder: return (.renamingOrder, 1)
        case .radioNoChange: return (.dateChanging, 0)
        case .radioOldest: return (.dateChanging, 1)
        case .radioNewest: return (.dateChanging, 2)
        case .radioTop: return (.sequenceDirection, 0)
        case .radioBottom: return (.sequenceDirection, 1)
        default: return nil
        }
    }

    private func lastFieldBeforeButtons() -> RenamePrefixTabField {
        let fields = enabledTabFields()
        if let defaultsIndex = fields.firstIndex(of: .defaults), defaultsIndex > 0 {
            return fields[defaultsIndex - 1]
        }
        return .radioOrder
    }

    private func isLastRadioField(_ field: RenamePrefixTabField) -> Bool {
        lastFieldBeforeButtons() == field
    }

    // MARK: - Buttons

    private var buttonRow: some View {
        HStack(spacing: 8) {
            Spacer()
            dialogButton("Defaults", field: .defaults) { resetToDefaults() }
                .frame(maxWidth: 80)
            // Python: `cancel_button.setDefault(True)` — Return cancels; Escape rejects via onExitCommand.
            dialogButton("Cancel", field: .cancel) { finish(nil) }
                .keyboardShortcut(.defaultAction)
            dialogButton("OK", field: .ok) { validateAndAccept() }
        }
    }

    private func dialogButton(
        _ title: String,
        field: RenamePrefixTabField,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            focus = field
            action()
        } label: {
            Text(title)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(focus == field ? colors.currentImageBorder : .clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focus, equals: field)
    }

    /// Python `reset_to_defaults` (digits / starting number are intentionally left alone).
    private func resetToDefaults() {
        prefixText = Self.defaultPrefix
        sortMode = .date
        dateChangeMode = .oldest
        orderDirection = .top
    }

    private func validateAndAccept() {
        let trimmed = prefixText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            StyledMessageDialog.showWarning(
                title: "Invalid Prefix",
                message: "Prefix cannot be blank. Please enter a prefix."
            )
            return
        }
        let mode = sortMode
        let dateMode: RenamePrefixPlanner.DateChangeMode = mode == .date ? .none : dateChangeMode
        let direction: RenamePrefixPlanner.OrderDirection = mode == .order ? orderDirection : .top
        finish(RenamePrefixPlanner.Options(
            prefixTemplate: trimmed,
            incrementLength: incrementLength,
            startingNumber: startingNumber,
            sortMode: mode,
            dateChangeMode: dateMode,
            orderDirection: direction
        ))
    }

    private func finish(_ options: RenamePrefixPlanner.Options?) {
        guard !finished else { return }
        finished = true
        appState.renamePrefixDialog = nil
        appState.renamePrefixService.dialogFinished(options)
    }
}

// MARK: - Sheet keyboard focus (block canvas routing; arrow keys move focus)

private enum RenamePrefixArrowDirection {
    case left, right, up, down
}

/// Local key monitor while the rename sheet is key — mirrors Qt dialog focus isolation.
private struct RenamePrefixKeyRoutingView: NSViewRepresentable {
    let isPresented: () -> Bool
    let onTab: (Bool) -> Void
    let onArrow: (RenamePrefixArrowDirection) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.startIfNeeded(host: view, parent: self)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.startIfNeeded(host: nsView, parent: self)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var parent: RenamePrefixKeyRoutingView?
        private var monitor: Any?

        func startIfNeeded(host: NSView, parent: RenamePrefixKeyRoutingView) {
            self.parent = parent
            guard monitor == nil else { return }
            DispatchQueue.main.async { host.window?.makeKey() }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let parent = self.parent, parent.isPresented() else { return event }
                guard Self.isSheetKeyWindow(event) else { return event }
                if event.keyCode == 48 { // Tab / Shift-Tab
                    parent.onTab(!event.modifierFlags.contains(.shift))
                    return nil
                }
                if Self.isTextInputFocused() { return event }
                if let direction = Self.arrowDirection(for: event.keyCode) {
                    parent.onArrow(direction)
                    return nil
                }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private static func arrowDirection(for keyCode: UInt16) -> RenamePrefixArrowDirection? {
            switch keyCode {
            case 123: return .left
            case 124: return .right
            case 125: return .down
            case 126: return .up
            default: return nil
            }
        }

        private static func isSheetKeyWindow(_ event: NSEvent) -> Bool {
            guard let keyWindow = NSApp.keyWindow else { return false }
            return event.window === keyWindow
        }

        private static func isTextInputFocused() -> Bool {
            guard let responder = NSApp.keyWindow?.firstResponder else { return false }
            if responder is NSTextView || responder is NSTextField || responder is NSSecureTextField {
                return true
            }
            let typeName = String(describing: type(of: responder))
            if typeName.contains("TextField") || typeName.contains("TextEditor") || typeName.contains("TextView") {
                return true
            }
            if let view = responder as? NSView {
                var current: NSView? = view
                while let candidate = current {
                    if candidate is NSTextView || candidate is NSTextField || candidate is NSSecureTextField {
                        return true
                    }
                    current = candidate.superview
                }
            }
            return false
        }
    }
}
