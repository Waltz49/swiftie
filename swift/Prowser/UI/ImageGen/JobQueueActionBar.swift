import AppKit
import SwiftUI

@MainActor
struct JobQueueActionBar: View {
    let row: QueueRowSnapshot
    let rowIndex: Int
    let onEdit: () -> Void
    let onCancel: (Bool) -> Void
    let onAddSeries: (Int, Bool) -> Void
    let onSubtractSeries: (Int, Bool) -> Void
    let onToggleImageRefinement: (Bool) -> Void
    let onToggleTextRefinement: (Bool) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button("+") { onAddSeries(1, false) }
                .help("Add one copy (Option+click for 51)")
            Button("−") { onSubtractSeries(1, false) }
                .help("Remove one remaining copy (Option+click to clear all)")
            Button("Img") { onToggleImageRefinement(true) }
                .help("Image series refinement")
            Button("Txt") { onToggleTextRefinement(true) }
                .help("Text series refinement")
            Spacer()
            Button("Edit", action: onEdit)
            Button("Cancel") { onCancel(false) }
                .help("Option+click to cancel this and all following jobs")
        }
        .font(.caption)
        .buttonStyle(.borderless)
    }
}
