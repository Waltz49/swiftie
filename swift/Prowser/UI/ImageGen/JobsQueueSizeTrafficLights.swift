import SwiftUI

/// Strip / one / all size controls for the Job Control titlebar (⌥[ ⌥] ⌥\\).
struct JobsQueueSizeTrafficLights: View {
    @Environment(AppState.self) private var appState

    private static let orderedModes: [JobsQueueSizeMode] = [.strip, .one, .all]
    private static let diameter: CGFloat = 11
    private static let spacing: CGFloat = 6

    var body: some View {
        let activeMode = appState.jobsQueueSizeMode
        HStack(spacing: Self.spacing) {
            ForEach(Self.orderedModes, id: \.self) { mode in
                Button {
                    _ = appState.setJobsQueueSizeMode(mode)
                } label: {
                    let isActive = mode == activeMode
                    Circle()
                        .fill(Self.color(for: mode))
                        .opacity(isActive ? 1 : 0.52)
                        .brightness(isActive ? 0.2 : 0.08)
                        .overlay {
                            if isActive {
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.45), lineWidth: 0.5)
                            }
                        }
                        .frame(width: Self.diameter, height: Self.diameter)
                }
                .buttonStyle(.plain)
                .help(Self.help(for: mode))
                .accessibilityLabel(Self.help(for: mode))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private static func color(for mode: JobsQueueSizeMode) -> Color {
        switch mode {
        case .strip:
            return Color(red: 1, green: 0.373, blue: 0.341)
        case .one:
            return Color(red: 1, green: 0.741, blue: 0.18)
        case .all:
            return Color(red: 0.157, green: 0.792, blue: 0.259)
        }
    }

    private static func help(for mode: JobsQueueSizeMode) -> String {
        switch mode {
        case .strip: return "Compact queue (⌥[)"
        case .one: return "Single job (⌥])"
        case .all: return "All jobs (⌥\\)"
        }
    }
}