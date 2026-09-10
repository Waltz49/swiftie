import SwiftUI

struct ImageGenFunctionSwitcher: View {
    @Binding var selectedFunction: String
    let availableFunctions: [String]

    private let order = ["edit", "create", "expand", "infill"]

    private let entries: [String: (icon: String, hover: String, tooltip: String)] = [
        "edit": ("editAI", "editAI_hover", "Edit an image with AI..."),
        "create": ("fromText", "fromText_hover", "Create an image from text..."),
        "expand": ("expand_icon", "expand_icon_hover", "Expand existing image..."),
        "infill": ("infill", "infill_hover", "Infill by painting..."),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(order.filter { availableFunctions.contains($0) }, id: \.self) { function in
                let entry = entries[function]!
                Button {
                    selectedFunction = function
                } label: {
                    let isSelected = selectedFunction == function
                    let imageName = isSelected ? entry.hover : entry.icon
                    Group {
                        if let image = AppAssets.image(name: imageName) {
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(width: 22, height: 22)
                        } else {
                            Image(systemName: "photo")
                                .frame(width: 22, height: 22)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.secondary.opacity(0.5),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .help(entry.tooltip)
            }
        }
    }
}
