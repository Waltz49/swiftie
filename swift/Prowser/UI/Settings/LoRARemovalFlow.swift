import AppKit

/// Confirmed LoRA removal (compatibility state vs weights on disk).
@MainActor
enum LoRARemovalFlow {
    enum Outcome {
        case cancelled
        case removedCompatibilityState
        case deletedWeights
    }

    static func run(
        info: LoRARemovalInfo,
        parentWindow: NSWindow?
    ) -> Outcome {
        let name = info.displayName
        let choice = StyledMessageDialog.present(
            title: "Remove LoRA",
            message:
                "What should happen to «\(name)»?\n\n"
                + "Remove compatibility state clears saved setup, compatibility test "
                + "results, and Create menu settings. The .safetensors file on disk is "
                + "not deleted; you can add it again from Needs setup.\n\n"
                + "Delete weights from disk removes the saved weight file (when stored "
                + "in the app cache) and all saved data for this LoRA.",
            style: .warning,
            icon: .warning,
            buttons: [
                StyledMessageDialog.Button("Cancel", role: .dismissive),
                StyledMessageDialog.Button("Remove compatibility state"),
                StyledMessageDialog.Button("Delete weights from disk"),
            ],
            defaultButtonIndex: 0,
            escapeButtonIndex: 0,
            parentWindow: parentWindow
        )

        switch choice {
        case 1:
            guard confirmRemoveCompatibilityState(name: name, parentWindow: parentWindow) else {
                return .cancelled
            }
            return .removedCompatibilityState
        case 2:
            guard confirmDeleteWeights(info: info, parentWindow: parentWindow) else {
                return .cancelled
            }
            return .deletedWeights
        default:
            return .cancelled
        }
    }

    private static func confirmRemoveCompatibilityState(
        name: String,
        parentWindow: NSWindow?
    ) -> Bool {
        StyledMessageDialog.showConfirm(
            title: "Remove compatibility state?",
            message:
                "«\(name)» will no longer appear as a saved LoRA.\n\n"
                + "Weight files on disk are kept. Run Test LoRAs again after you set "
                + "the file up from Needs setup.",
            confirmTitle: "Remove",
            cancelTitle: "Cancel",
            defaultCancel: true,
            parentWindow: parentWindow
        )
    }

    private static func confirmDeleteWeights(
        info: LoRARemovalInfo,
        parentWindow: NSWindow?
    ) -> Bool {
        var message =
            "Delete weight files for «\(info.displayName)» and remove all saved "
            + "LoRA data?\n\n"
            + "You will need the original file or a download again to use this LoRA."
        if !info.sharedModelLabels.isEmpty {
            let models = info.sharedModelLabels.joined(separator: ", ")
            message +=
                "\n\nThis LoRA is shared across base models: \(models). "
                + "Deleting weights will stop it from working on every model that uses this file."
        }
        return StyledMessageDialog.showConfirm(
            title: "Delete weights from disk?",
            message: message,
            confirmTitle: "Delete weights",
            cancelTitle: "Cancel",
            defaultCancel: true,
            parentWindow: parentWindow
        )
    }
}
