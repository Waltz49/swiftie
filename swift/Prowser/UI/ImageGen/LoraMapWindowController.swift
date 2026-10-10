import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Tools → Debug → Map LoRAs. Loads the same rows as Python ``_lora_map_rows``.
@MainActor
enum LoraMapService {
    static func fetchRows(config: AppConfig) async throws -> [LoraMapRow] {
        let venvPython = config.imagegenVenvPythonPath()
        guard FileManager.default.isExecutableFile(atPath: venvPython) else {
            throw BridgeError.workerMessage(
                "Image generation Python was not found at \(venvPython)."
            )
        }
        guard let located = PythonLocator.resolve(profilePath: nil, config: config) else {
            throw BridgeError.pythonUnavailable
        }
        let environment = PythonLocator.Environment(
            executable: venvPython,
            bundleRoot: located.bundleRoot,
            profilePath: located.profilePath
        )
        let script = scriptURL(bundleRoot: environment.bundleRoot)
        guard FileManager.default.isReadableFile(atPath: script.path) else {
            throw BridgeError.workerMessage("LoRA map script was not found at \(script.path).")
        }
        return try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: environment.executable)
            proc.arguments = ["-u", script.path]
            proc.currentDirectoryURL = environment.bundleRoot
            proc.environment = PythonLocator.processEnvironment(for: environment)
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe
            let stdout = CollectedPipe()
            let stderr = CollectedPipe()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    stdout.append(chunk)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    stderr.append(chunk)
                }
            }
            try proc.run()
            proc.waitUntilExit()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdout.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            stderr.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            let data = stdout.data()
            guard proc.terminationStatus == 0,
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                let detail = String(data: stderr.data(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw BridgeError.workerMessage(detail.isEmpty ? "Could not load LoRA map." : detail)
            }
            return raw.compactMap(LoraMapRow.fromDictionary)
        }.value
    }

    private static func scriptURL(bundleRoot: URL) -> URL {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("run_lora_map.py"),
            bundleRoot.appendingPathComponent("run_lora_map.py"),
            // Dev tree: ImageGenPython's sibling Scripts/ (swift/Scripts, not the repo root).
            bundleRoot
                .deletingLastPathComponent()
                .appendingPathComponent("Scripts/run_lora_map.py"),
            sourceTreeScriptURL(),
        ]
        for candidate in candidates {
            guard let candidate, FileManager.default.isReadableFile(atPath: candidate.path) else { continue }
            return candidate
        }
        return sourceTreeScriptURL()
    }

    /// `Prowser/UI/ImageGen/…swift` → `swift/Scripts/run_lora_map.py`.
    private static func sourceTreeScriptURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Scripts/run_lora_map.py")
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
            return LoraMapModel(label: name, crossFamily: item["cross_family"] as? Bool ?? false)
        }
        return LoraMapRow(loraID: loraID, loraLabel: label, models: models)
    }
}

/// Filter and plain-text export matching ``filter_lora_map_rows`` / ``build_lora_map_text``.
enum LoraMapFormatting {
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
            lines.append("(No LoRA model-support map yet. Run Check LoRAs first.)")
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
            lines.append("No associated models (host or Check LoRAs probe).")
            for row in unused {
                lines.append("")
                lines.append(row.loraLabel)
            }
        }
        lines.append("")
        lines.append(
            "* cross-family — Check LoRAs found this LoRA "
                + "working on a base model outside its catalog host family."
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
            return
        }

        let host = NSHostingController(
            rootView: LoraMapView(onClose: { [weak self] in
                self?.window?.close()
            })
            .environment(appState)
        )
        let window = NSWindow(contentViewController: host)
        window.title = "Map LoRAs"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.minSize = NSSize(width: 520, height: 400)
        window.setContentSize(NSSize(width: 720, height: 640))
        window.isReleasedWhenClosed = false
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
    @Environment(AppState.self) private var appState
    @Environment(\.themeColors) private var colors
    var onClose: () -> Void

    @State private var rows: [LoraMapRow] = []
    @State private var filter = ""
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var errorMessage: String?

    private var filteredRows: [LoraMapRow] {
        LoraMapFormatting.filter(rows, needle: filter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Map LoRAs")
                .font(.system(size: 18, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 4) {
                Text("Filter:")
                TextField("Filter LoRAs or models…", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(filter.isEmpty)
                .help("Clear filter")
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
        .task { await load() }
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
        } else {
            ScrollView {
                LoraMapContent(rows: filteredRows, loadError: loadError)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func load() async {
        isLoading = true
        do {
            rows = try await LoraMapService.fetchRows(config: appState.config)
            loadError = nil
            errorMessage = nil
        } catch {
            rows = []
            loadError = error.localizedDescription
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
                Text("(No LoRA model-support map yet. Run Check LoRAs first.)")
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

                Text("No associated models (host or Check LoRAs probe).")
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
                "* cross-family — Check LoRAs found this LoRA "
                    + "working on a base model outside its catalog host family."
            )
            .font(.system(size: 11))
            .foregroundStyle(colors.dialogMutedText)
            .padding(.top, 4)
        }
    }
}
