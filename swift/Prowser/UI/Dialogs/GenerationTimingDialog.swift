import AppKit
import SwiftUI

/// Tools > Debug > See timings — port of ``generation_timing_dialog.py``.
@MainActor
final class GenerationTimingDialogController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var appState: AppState?

    func show(appState: AppState) {
        self.appState = appState
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: GenerationTimingDialogView().environment(appState))
        let window = NSWindow(contentViewController: host)
        window.title = "Generation Timings"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.minSize = NSSize(width: 720, height: 360)
        window.setContentSize(NSSize(width: 860, height: 420))
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        DialogGeometryPersistence.apply(
            to: window,
            config: appState.config,
            key: DialogGeometryKey.generationTiming,
            defaultSize: NSSize(width: 860, height: 420),
            minSize: NSSize(width: 720, height: 360)
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let window, let appState {
            DialogGeometryPersistence.saveFrame(
                config: appState.config,
                key: DialogGeometryKey.generationTiming,
                frame: window.frame
            )
        }
        self.window = nil
        self.appState = nil
    }
}

private struct GenerationTimingChartSeries: Identifiable {
    let id: String
    let label: String
    let color: Color
    let points: [(area: Double, seconds: Double)]
}

private struct GenerationTimingDialogView: View {
    @Environment(AppState.self) private var appState
    @State private var rows: [GenerationTimingRow] = []
    @State private var filterText = ""
    @State private var selectedRowID: GenerationTimingRow.ID?
    @State private var sortOrder = [KeyPathComparator(\GenerationTimingRow.modelName)]

    private let seriesColors: [Color] = [
        Color(red: 0.31, green: 0.47, blue: 0.65),
        Color(red: 0.95, green: 0.56, blue: 0.17),
        Color(red: 0.88, green: 0.34, blue: 0.35),
        Color(red: 0.46, green: 0.72, blue: 0.70),
        Color(red: 0.35, green: 0.63, blue: 0.31),
        Color(red: 0.93, green: 0.79, blue: 0.28),
        Color(red: 0.69, green: 0.48, blue: 0.63),
        Color(red: 1.0, green: 0.62, blue: 0.65),
        Color(red: 0.61, green: 0.46, blue: 0.37),
        Color(red: 0.73, green: 0.69, blue: 0.67),
    ]

    private var filteredRows: [GenerationTimingRow] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { $0.modelName.lowercased().contains(needle) }
    }

    private var chartSeries: [GenerationTimingChartSeries] {
        let visible = filteredRows
        let modelNames = Set(visible.map(\.modelName))
        guard modelNames.count == 1 else { return [] }
        var groups: [String: [(Double, Double)]] = [:]
        for row in visible {
            let quantLabel = row.quant.isEmpty ? "(none)" : row.quant
            let label = "\(row.steps):\(quantLabel)"
            groups[label, default: []].append((Double(row.width * row.height), row.avgSeconds))
        }
        return groups.keys.sorted().enumerated().map { index, label in
            let points = (groups[label] ?? []).sorted { $0.0 < $1.0 }
            return GenerationTimingChartSeries(
                id: label,
                label: label,
                color: seriesColors[index % seriesColors.count],
                points: points.map { (area: $0.0, seconds: $0.1) }
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Filter:")
                TextField("Filter models…", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(filterText.isEmpty)
                .help("Clear filter")
                Spacer()
            }

            if chartSeries.isEmpty {
                tableView
            } else {
                VSplitView {
                    tableView
                        .frame(minHeight: 180)
                    GenerationTimingAreaChartView(series: chartSeries)
                        .frame(minHeight: 120)
                }
            }

            HStack {
                Spacer()
                Button("Refresh") {
                    Task { await reloadRows() }
                }
                Button("Close") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 360)
        .themeDialogStyle()
        .task { await reloadRows() }
    }

    private var tableView: some View {
        Table(filteredRows, selection: $selectedRowID, sortOrder: $sortOrder) {
            TableColumn("Model", value: \.modelName)
            TableColumn("Size", value: \.size)
            TableColumn("Area") { row in
                Text(GenerationTimingStats.formatAreaK(width: row.width, height: row.height))
            }
            .width(min: 56)
            TableColumn("Steps") { row in
                Text("\(row.steps)")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 48)
            TableColumn("Quant", value: \.quant)
            TableColumn("Runs") { row in
                Text("\(row.runCount)")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 48)
            TableColumn("Time") { row in
                Text(GenerationTimingStats.formatDuration(row.avgSeconds))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .contextMenu(forSelectionType: GenerationTimingRow.ID.self) { selection in
            if let id = selection.first, let row = filteredRows.first(where: { $0.id == id }) {
                Button("Filter to \(row.modelName)") {
                    filterText = row.modelName
                }
            }
        } primaryAction: { selection in
            if let id = selection.first, let row = filteredRows.first(where: { $0.id == id }) {
                filterText = row.modelName
            }
        }
    }

    @MainActor
    private func reloadRows() async {
        let names = await loadModelDisplayNames()
        rows = GenerationTimingStats.listTimingRows(
            dataDirectory: appState.config.dataDirectory,
            modelDisplayNames: names
        )
    }

    private func loadModelDisplayNames() async -> [String: String] {
        guard let plugins = try? await appState.workers.imageGenRegistry.listPlugins() else {
            return [:]
        }
        var names: [String: String] = [:]
        for plugin in plugins {
            let label = (plugin["display_name"] as? String)
                ?? (plugin["model_label"] as? String)
                ?? (plugin["plugin_id"] as? String)
                ?? ""
            guard !label.isEmpty else { continue }
            if let pluginID = plugin["plugin_id"] as? String, !pluginID.isEmpty {
                names[pluginID] = label
            }
            if let hfModelID = plugin["hf_model_id"] as? String, !hfModelID.isEmpty {
                names[hfModelID] = label
            }
        }
        return names
    }
}

private struct GenerationTimingAreaChartView: View {
    let series: [GenerationTimingChartSeries]

    var body: some View {
        GeometryReader { _ in
            Canvas { context, size in
                drawChart(context: &context, size: size)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .bottom) {
                Text("Area (K pixels)")
                    .font(.caption2)
                    .padding(.bottom, 2)
            }
            .overlay(alignment: .leading) {
                Text("Time (mm:ss)")
                    .font(.caption2)
                    .rotationEffect(.degrees(-90))
                    .fixedSize()
                    .padding(.leading, 2)
            }
        }
    }

    private func drawChart(context: inout GraphicsContext, size: CGSize) {
        let plot = CGRect(x: 56, y: 12, width: max(1, size.width - 168), height: max(1, size.height - 36))
        guard plot.width > 20, plot.height > 20 else { return }

        var allAreas: [Double] = []
        var allSeconds: [Double] = []
        for item in series {
            for point in item.points {
                allAreas.append(point.area)
                allSeconds.append(point.seconds)
            }
        }
        guard let minArea = allAreas.min(), let maxArea = allAreas.max(),
              let minSeconds = allSeconds.min(), let maxSeconds = allSeconds.max() else {
            return
        }

        let (xMin, xMax) = paddedRange(minArea, maxArea)
        let (yMin, yMax) = paddedRange(minSeconds, maxSeconds)

        func mapX(_ area: Double) -> CGFloat {
            plot.minX + CGFloat((area - xMin) / max(xMax - xMin, 1)) * plot.width
        }
        func mapY(_ seconds: Double) -> CGFloat {
            plot.maxY - CGFloat((seconds - yMin) / max(yMax - yMin, 1)) * plot.height
        }

        var axis = Path()
        axis.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        axis.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        axis.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
        context.stroke(axis, with: .color(.secondary.opacity(0.6)), lineWidth: 1)

        for item in series {
            let mapped = item.points.map { CGPoint(x: mapX($0.area), y: mapY($0.seconds)) }
            guard !mapped.isEmpty else { continue }
            if mapped.count >= 2 {
                var line = Path()
                line.move(to: mapped[0])
                for point in mapped.dropFirst() {
                    line.addLine(to: point)
                }
                context.stroke(line, with: .color(item.color), lineWidth: 2)
            }
            for point in mapped {
                let rect = CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)
                context.fill(Path(rect), with: .color(item.color))
            }
        }

        var legendY = plot.minY
        let legendX = plot.maxX + 12
        for item in series {
            let colorRect = CGRect(x: legendX, y: legendY, width: 8, height: 8)
            context.fill(Path(colorRect), with: .color(item.color))
            let text = Text(item.label).font(.caption2)
            context.draw(text, at: CGPoint(x: legendX + 12, y: legendY + 4), anchor: .leading)
            legendY += 14
        }
    }

    private func paddedRange(_ minValue: Double, _ maxValue: Double) -> (Double, Double) {
        if maxValue <= minValue {
            let mid = maxValue > 0 ? maxValue : 1
            return (0, mid * 1.1)
        }
        let span = maxValue - minValue
        let pad = span * 0.08
        return (minValue - pad, maxValue + pad)
    }
}
