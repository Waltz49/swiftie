import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Map LoRAs should re-read ``lora_catalog.json`` (raise window, catalog edits, Test LoRAs progress).
    static let prowserLoraMapShouldReload = Notification.Name("prowser.loraMapShouldReload")
}

/// Image → Map LoRAs. Loads the same rows as Python ``_lora_map_rows``.
@MainActor
enum LoraMapService {
    static func fetchRows(config: AppConfig) async throws -> [LoraMapRow] {
        let store = LoRACatalogStore(paths: config.profilePaths)
        let lc = store.load()
        return LoRAMapRows.rows(lc: lc).map { row in
            LoraMapRow(
                loraID: row.loraID,
                loraLabel: row.loraLabel,
                models: row.models.map {
                    LoraMapModel(
                        modelKey: $0.modelKey,
                        label: $0.label,
                        crossFamily: $0.crossFamily
                    )
                }
            )
        }
    }
}

private final class CollectedPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

struct LoraMapModel: Hashable {
    let modelKey: String
    let label: String
    let crossFamily: Bool
}

struct LoraMapRow: Identifiable, Hashable {
    /// Catalog id. Display names are not unique.
    let loraID: String
    let loraLabel: String
    let models: [LoraMapModel]
    var id: String { loraID }

    static func fromDictionary(_ dict: [String: Any]) -> LoraMapRow? {
        guard let label = dict["lora_label"] as? String else { return nil }
        let loraID = (dict["lora_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? label
        let modelsRaw = dict["models"] as? [[String: Any]] ?? []
        let models = modelsRaw.compactMap { item -> LoraMapModel? in
            guard let name = item["label"] as? String else { return nil }
            let cross = item["cross_family"] as? Bool ?? false
            let modelKey = (item["model_key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? LoraMapFormatting.modelKey(matchingDisplayLabel: name)
            return LoraMapModel(modelKey: modelKey, label: name, crossFamily: cross)
        }
        return LoraMapRow(loraID: loraID, loraLabel: label, models: models)
    }
}

/// Filter and plain-text export matching ``filter_lora_map_rows`` / ``build_lora_map_text``.
enum LoraMapFormatting {
    struct LoraMapModelGroupLora: Hashable, Identifiable {
        let loraID: String
        let loraLabel: String
        let crossFamily: Bool
        var id: String { loraID }
    }

    struct LoraMapModelGroup: Hashable, Identifiable {
        let modelKey: String
        let displayName: String
        let loras: [LoraMapModelGroupLora]
        var id: String { modelKey }
    }

    /// Resolve probe model key from a map model display label (strips trailing cross-family ``*``).
    static func modelKey(matchingDisplayLabel label: String) -> String {
        let stripped = label.hasSuffix(" *") ? String(label.dropLast(2)) : label
        for mk in LoRAHFModelIDs.probeModelOrder {
            if LoRAHFModelIDs.displayName(for: mk) == stripped {
                return mk
            }
        }
        return stripped
    }

    static func modelGroups(from rows: [LoraMapRow]) -> [LoraMapModelGroup] {
        var byKey: [String: [LoraMapModelGroupLora]] = [:]
        for row in rows where !row.models.isEmpty {
            for model in row.models {
                let entry = LoraMapModelGroupLora(
                    loraID: row.loraID,
                    loraLabel: row.loraLabel,
                    crossFamily: model.crossFamily
                )
                byKey[model.modelKey, default: []].append(entry)
            }
        }
        var groups: [LoraMapModelGroup] = []
        for mk in LoRAHFModelIDs.probeModelOrder {
            guard var loras = byKey[mk], !loras.isEmpty else { continue }
            loras.sort { $0.loraLabel.localizedCaseInsensitiveCompare($1.loraLabel) == .orderedAscending }
            groups.append(
                LoraMapModelGroup(
                    modelKey: mk,
                    displayName: LoRAHFModelIDs.displayName(for: mk),
                    loras: loras
                )
            )
        }
        return groups
    }

    static func filter(_ rows: [LoraMapRow], needle: String) -> [LoraMapRow] {
        let query = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return rows }
        var matched: [LoraMapRow] = []
        for row in rows {
            if row.loraLabel.lowercased().contains(query) {
                matched.append(row)
                continue
            }
            let models = row.models.filter { $0.label.lowercased().contains(query) }
            if !models.isEmpty {
                matched.append(LoraMapRow(loraID: row.loraID, loraLabel: row.loraLabel, models: models))
            }
        }
        return matched
    }

    static func plainText(for rows: [LoraMapRow]) -> String {
        let used = rows.filter { !$0.models.isEmpty }
        let unused = rows.filter { $0.models.isEmpty }
        var lines = [summary(for: rows)]
        if rows.isEmpty {
            lines.append("(No LoRA model-support map yet. Run Test LoRAs first.)")
        }
        for row in used {
            lines.append("")
            lines.append(row.loraLabel)
            for model in row.models {
                lines.append("  - \(model.label)")
            }
        }
        if !unused.isEmpty {
            lines.append("")
            lines.append("Unused LoRAs")
            lines.append("No associated models (host or Test LoRAs probe).")
            for row in unused {
                lines.append("")
                lines.append(row.loraLabel)
            }
        }
        lines.append("")
        lines.append(
            "* cross-family — Test LoRAs found this LoRA "
                + "working on a base model outside its usual family."
        )
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func plainTextByModel(for rows: [LoraMapRow]) -> String {
        let groups = modelGroups(from: rows)
        var lines = [summary(for: rows)]
        if rows.isEmpty {
            lines.append("(No LoRA model-support map yet. Run Test LoRAs first.)")
        }
        for group in groups {
            lines.append("")
            lines.append(group.displayName)
            for lora in group.loras {
                let suffix = lora.crossFamily ? " *" : ""
                lines.append("  - \(lora.loraLabel)\(suffix)")
            }
        }
        lines.append("")
        lines.append(
            "* cross-family — Test LoRAs found this LoRA "
                + "working on a base model outside its usual family."
        )
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func summary(for rows: [LoraMapRow]) -> String {
        let used = rows.filter { !$0.models.isEmpty }
        let unusedCount = rows.count - used.count
        let crossCount = used.reduce(0) { count, row in
            count + row.models.filter(\.crossFamily).count
        }
        var text = "\(rows.count) LoRA(s); \(used.count) with at least one model; \(unusedCount) unused."
        if crossCount > 0 {
            text += " \(crossCount) cross-family link(s)."
        }
        return text
    }
}

/// Non-modal Map LoRAs window. Raises the existing window; a new open reloads the map.
@MainActor
final class LoraMapWindowController: NSObject, NSWindowDelegate {
    static let shared = LoraMapWindowController()

    private var window: NSWindow?
    private weak var appState: AppState?

    func show(appState: AppState) {
        self.appState = appState
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .prowserLoraMapShouldReload, object: nil)
            return
        }

        let host = NSHostingController(
            rootView: DialogCopyFeedbackRoot {
                LoraMapView(onClose: { [weak self] in
                    self?.window?.close()
                })
            }
            .environment(appState)
        )
        let window = AuxiliaryDialogWindow(contentViewController: host)
        window.title = "Map LoRAs"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.minSize = NSSize(width: 520, height: 400)
        window.setContentSize(NSSize(width: 720, height: 640))
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.identifier = NSUserInterfaceItemIdentifier(BrowserWindowIdentity.dialogPrefix + "loraMap")
        window.delegate = self
        self.window = window
        DialogGeometryPersistence.apply(
            to: window,
            config: appState.config,
            key: DialogGeometryKey.loraMap,
            defaultSize: NSSize(width: 720, height: 640),
            minSize: NSSize(width: 520, height: 400)
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let window, let appState {
            DialogGeometryPersistence.saveFrame(
                config: appState.config,
                key: DialogGeometryKey.loraMap,
                frame: window.frame
            )
        }
        self.window = nil
        self.appState = nil
    }
}

@MainActor
private struct LoraMapView: View {
    private enum MapTab: String, CaseIterable, Identifiable {
        case byLora
        case byModel
        case fileLocations

        var id: String { rawValue }

        var title: String {
            switch self {
            case .byLora: "By LoRA"
            case .byModel: "By model"
            case .fileLocations: "File locations"
            }
        }

        init?(storageKey: String) {
            guard let match = Self.allCases.first(where: { $0.rawValue == storageKey }) else { return nil }
            self = match
        }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.themeColors) private var colors
    var onClose: () -> Void

    @State private var rows: [LoraMapRow] = []
    @State private var imageGenLocations: [LoraMapFileLocations.Row] = []
    @State private var loraLocations: [LoraMapFileLocations.Row] = []
    @State private var filter = ""
    @State private var mapTab: MapTab = .byLora
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var errorMessage: String?

    private var filteredRows: [LoraMapRow] {
        LoraMapFormatting.filter(rows, needle: filter)
    }

    private var filteredModelGroups: [LoraMapFormatting.LoraMapModelGroup] {
        LoraMapFormatting.modelGroups(from: filteredRows)
    }

    private var filteredImageGenLocations: [LoraMapFileLocations.Row] {
        LoraMapFileLocations.filter(imageGenLocations, needle: filter)
    }

    private var filteredLoraLocations: [LoraMapFileLocations.Row] {
        LoraMapFileLocations.filter(loraLocations, needle: filter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Map LoRAs")
                .font(.system(size: 18, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 4) {
                Text("Filter:")
                ClearableFilterField(
                    placeholder: "Filter LoRAs or models…",
                    text: $filter,
                    minFieldWidth: 220,
                    clearHelp: "Clear filter"
                )
                Spacer()
            }

            mapBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
                .background(colors.dialogBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(colors.defaultBorder, lineWidth: 1)
                )

            HStack {
                Spacer()
                DialogButtonRow(
                    [
                        DialogButton("Copy", isEnabled: !isLoading && loadError == nil) {
                            copyCurrentTab()
                        },
                        DialogButton("Save", isEnabled: !isLoading && loadError == nil) {
                            saveText()
                        },
                        DialogButton("Close", isDefault: true, isCancel: true) {
                            onClose()
                        },
                    ],
                    focusDefaultOnAppear: true,
                    layout: .inline
                )
                Spacer()
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 400)
        .themeDialogStyle()
        .onExitCommand { onClose() }
        .onAppear {
            if let key = appState.config.loraMapDialogTabFromSettings(),
               let restored = MapTab(storageKey: key) {
                mapTab = restored
            }
        }
        .onChange(of: mapTab) { _, tab in
            appState.config.persistLoraMapDialogTab(tab.rawValue)
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .prowserLoraMapShouldReload)) { _ in
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserLoraCatalogChanged)) { _ in
            Task { await load() }
        }
        .alert("Map LoRAs", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var mapBody: some View {
        if isLoading {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading LoRA map…")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.dialogMutedText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loadError != nil {
            Text(loadError ?? "")
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Picker("View", selection: $mapTab) {
                    ForEach(MapTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                ScrollView {
                    Group {
                        switch mapTab {
                        case .byLora:
                            LoraMapContent(rows: filteredRows, loadError: nil)
                        case .byModel:
                            LoraMapModelContent(rows: filteredRows, modelGroups: filteredModelGroups)
                        case .fileLocations:
                            LoraMapFileLocationsContent(
                                imageGenRows: filteredImageGenLocations,
                                loraRows: filteredLoraLocations
                            )
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func load() async {
        isLoading = true
        do {
            rows = try await LoraMapService.fetchRows(config: appState.config)
            let locations = LoraMapFileLocations.build(config: appState.config)
            imageGenLocations = locations.imageGen
            loraLocations = locations.loras
            loadError = nil
            errorMessage = nil
        } catch {
            rows = []
            imageGenLocations = []
            loraLocations = []
            loadError = error.localizedDescription
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func copyCurrentTab() {
        let text: String
        switch mapTab {
        case .byLora:
            text = LoraMapFormatting.plainText(for: filteredRows)
        case .byModel:
            text = LoraMapFormatting.plainTextByModel(for: filteredRows)
        case .fileLocations:
            text = LoraMapFileLocations.plainText(
                imageGenRows: filteredImageGenLocations,
                loraRows: filteredLoraLocations
            )
        }
        appState.copyTextToClipboard(text)
    }

    private func saveText() {
        let stamp = Self.saveStamp.string(from: Date())
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
        let panel = NSSavePanel()
        panel.title = "Save LoRA Map"
        panel.allowedContentTypes = [.plainText]
        panel.directoryURL = downloads
        panel.nameFieldStringValue = "lora_map_\(stamp).txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != "txt" {
            url = url.appendingPathExtension("txt")
        }
        let text = LoraMapFormatting.plainText(for: rows)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            StyledMessageDialog.present(
                title: "Save LoRA Map",
                message: "Could not save:\n\(error.localizedDescription)",
                style: .warning,
                icon: .warning,
                parentWindow: NSApp.keyWindow
            )
        }
    }

    private static let saveStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()
}

private struct LoraMapContent: View {
    @Environment(\.themeColors) private var colors
    let rows: [LoraMapRow]
    var loadError: String?

    private var used: [LoraMapRow] { rows.filter { !$0.models.isEmpty } }
    private var unused: [LoraMapRow] { rows.filter { $0.models.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let loadError {
                Text(loadError)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
            } else {
                catalogBody
            }
        }
    }

    private var catalogBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LoraMapFormatting.summary(for: rows))
                .font(.system(size: 12))
                .foregroundStyle(colors.dialogMutedText)
                .padding(.bottom, 12)

            if rows.isEmpty {
                Text("(No LoRA model-support map yet. Run Test LoRAs first.)")
                    .font(.system(size: 12))
            }

            ForEach(used) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.loraLabel)
                        .font(.system(size: 12, weight: .bold))
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(row.models.enumerated()), id: \.offset) { _, model in
                            Text("• \(model.label)")
                                .font(.system(size: 12))
                        }
                    }
                    .padding(.leading, 16)
                }
                .padding(.bottom, 8)
            }

            if !unused.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unused LoRAs")
                        .font(.system(size: 13, weight: .bold))
                    Rectangle()
                        .fill(colors.defaultBorder)
                        .frame(height: 1)
                }
                .padding(.top, 8)
                .padding(.bottom, 8)

                Text("No associated models (host or Test LoRAs probe).")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.dialogMutedText)
                    .padding(.bottom, 8)

                ForEach(unused) { row in
                    Text(row.loraLabel)
                        .font(.system(size: 12, weight: .bold))
                        .padding(.bottom, 8)
                }
            }

            Text(
                "* cross-family — Test LoRAs found this LoRA "
                    + "working on a base model outside its usual family."
            )
            .font(.system(size: 11))
            .foregroundStyle(colors.dialogMutedText)
            .padding(.top, 4)
        }
    }
}

private struct LoraMapModelContent: View {
    @Environment(\.themeColors) private var colors
    let rows: [LoraMapRow]
    let modelGroups: [LoraMapFormatting.LoraMapModelGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LoraMapFormatting.summary(for: rows))
                .font(.system(size: 12))
                .foregroundStyle(colors.dialogMutedText)
                .padding(.bottom, 12)

            if rows.isEmpty {
                Text("(No LoRA model-support map yet. Run Test LoRAs first.)")
                    .font(.system(size: 12))
            }

            ForEach(modelGroups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayName)
                        .font(.system(size: 12, weight: .bold))
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(group.loras) { lora in
                            Text("• \(lora.loraLabel)\(lora.crossFamily ? " *" : "")")
                                .font(.system(size: 12))
                        }
                    }
                    .padding(.leading, 16)
                }
                .padding(.bottom, 8)
            }

            Text(
                "* cross-family — Test LoRAs found this LoRA "
                    + "working on a base model outside its usual family."
            )
            .font(.system(size: 11))
            .foregroundStyle(colors.dialogMutedText)
            .padding(.top, 4)
        }
    }
}

private struct LoraMapFileLocationsContent: View {
    @Environment(\.themeColors) private var colors
    let imageGenRows: [LoraMapFileLocations.Row]
    let loraRows: [LoraMapFileLocations.Row]

    /// Tighter than default 12pt body (long paths wrap often on this tab).
    private let listLineSpacing: CGFloat = -3
    private let entrySeparatorHeight: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fileLocationSection(
                title: "LoRAs",
                rows: loraRows,
                emptyMessage: "No LoRA weight files found on disk."
            )
            .padding(.bottom, 16)

            fileLocationSection(
                title: "Image Generation Models",
                rows: imageGenRows,
                emptyMessage: "No image generation models installed locally."
            )
        }
    }

    @ViewBuilder
    private func fileLocationSection(
        title: String,
        rows: [LoraMapFileLocations.Row],
        emptyMessage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
            Rectangle()
                .fill(colors.defaultBorder)
                .frame(height: 1)
        }
        .padding(.bottom, 8)

        if rows.isEmpty {
            Text(emptyMessage)
                .font(.system(size: 12))
                .lineSpacing(listLineSpacing)
                .foregroundStyle(colors.dialogMutedText)
                .padding(.bottom, 4)
        } else {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.label)
                        .font(.system(size: 12, weight: .bold))
                        .lineSpacing(listLineSpacing)
                    Text("• \(row.path)")
                        .font(.system(size: 12))
                        .lineSpacing(listLineSpacing)
                        .padding(.leading, 16)
                    if index < rows.count - 1 {
                        Spacer()
                            .frame(height: entrySeparatorHeight)
                    }
                }
            }
        }
    }
}
