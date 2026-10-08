import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum LoraMapService {
    static func fetchRows(config: AppConfig) async throws -> [LoraMapRow] {
        guard let environment = PythonLocator.resolve(profilePath: nil, config: config) else {
            throw BridgeError.pythonUnavailable
        }
        let script = scriptURL(bundleRoot: environment.bundleRoot)
        return try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: environment.executable)
            proc.arguments = ["-u", script.path]
            proc.currentDirectoryURL = environment.bundleRoot
            proc.environment = PythonLocator.processEnvironment(for: environment)
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard proc.terminationStatus == 0,
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw BridgeError.workerMessage("Could not load LoRA map.")
            }
            return raw.compactMap(LoraMapRow.fromDictionary)
        }.value
    }

    private static func scriptURL(bundleRoot: URL) -> URL {
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("run_lora_map.py"),
           FileManager.default.isReadableFile(atPath: resource.path) {
            return resource
        }
        return bundleRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Scripts/run_lora_map.py")
    }
}

struct LoraMapRow: Identifiable {
    let loraLabel: String
    let models: [(label: String, crossFamily: Bool)]
    var id: String { loraLabel }

    static func fromDictionary(_ dict: [String: Any]) -> LoraMapRow? {
        guard let label = dict["lora_label"] as? String else { return nil }
        let modelsRaw = dict["models"] as? [[String: Any]] ?? []
        let models = modelsRaw.compactMap { m -> (String, Bool)? in
            guard let name = m["label"] as? String else { return nil }
            return (name, m["cross_family"] as? Bool ?? false)
        }
        return LoraMapRow(loraLabel: label, models: models)
    }
}

@MainActor
final class LoraMapWindowController {
    static let shared = LoraMapWindowController()
    private var window: NSWindow?

    func show(appState: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = LoraMapView()
            .environment(appState)
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Map LoRAs"
        win.setContentSize(NSSize(width: 640, height: 520))
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
    }
}

@MainActor
struct LoraMapView: View {
    @Environment(AppState.self) private var appState
    @State private var rows: [LoraMapRow] = []
    @State private var filter = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Filter LoRAs or models…", text: $filter)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(filteredRows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.loraLabel).fontWeight(.bold)
                            ForEach(row.models.indices, id: \.self) { idx in
                                let model = row.models[idx]
                                Text("• \(model.label)\(model.crossFamily ? " *" : "")")
                                    .font(.caption)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("* cross-family — Check LoRAs found this LoRA on a non-host model.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Save…") { saveText() }
                Button("Close") { NSApp.keyWindow?.close() }
            }
        }
        .padding()
        .task { await load() }
        .alert("Map LoRAs", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var filteredRows: [LoraMapRow] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { row in
            if row.loraLabel.lowercased().contains(q) { return true }
            return row.models.contains { $0.label.lowercased().contains(q) }
        }
    }

    private func load() async {
        do {
            rows = try await LoraMapService.fetchRows(config: appState.config)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveText() {
        var lines: [String] = ["\(filteredRows.count) LoRA(s)"]
        for row in filteredRows {
            lines.append("")
            lines.append(row.loraLabel)
            for model in row.models {
                let suffix = model.crossFamily ? " *" : ""
                lines.append("  • \(model.label)\(suffix)")
            }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "lora_map.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
