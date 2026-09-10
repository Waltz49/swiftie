import AppKit
import SwiftUI

/// Slideshow mode 1 — timed image advance with opacity transition.
struct SlideshowView: View {
    @Environment(AppState.self) private var appState

    @State private var slideIndex = 0
    @State private var stepDirection = 1
    @State private var timer: Timer?
    @State private var imageOpacity = 1.0
    @State private var loadedImage: NSImage?
    @State private var settingsObserver: UUID?

    var body: some View {
        let images = slideshowImages()
        let interval = slideshowInterval()
        let transitionDuration = slideshowTransitionDuration()

        ZStack {
            Color.black.ignoresSafeArea()

            if let loadedImage {
                Image(nsImage: loadedImage)
                    .resizable()
                    .scaledToFit()
                    .opacity(imageOpacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No images to show")
                    .foregroundStyle(.white.opacity(0.7))
            }

            VStack {
                Spacer()
                HStack {
                    Text(slideshowStatus(images: images))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Button("Exit (Esc)") {
                        exitSlideshow()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .padding()
                .background(.black.opacity(0.35))
            }
        }
        .onAppear {
            slideIndex = appState.fileData.currentIndex
            loadCurrentImage(images: images)
            startTimer(images: images, interval: interval, transitionDuration: transitionDuration)
            if settingsObserver == nil {
                settingsObserver = appState.eventBus.subscribe(.settingsChanged) { _ in
                    Task { @MainActor in
                        let images = slideshowImages()
                        startTimer(
                            images: images,
                            interval: slideshowInterval(),
                            transitionDuration: slideshowTransitionDuration()
                        )
                    }
                }
            }
        }
        .onChange(of: appState.fileData.currentIndex) { _, newIndex in
            slideIndex = newIndex
            loadCurrentImage(images: slideshowImages())
        }
        .onDisappear {
            stopTimer()
            if let settingsObserver {
                appState.eventBus.unsubscribe(.settingsChanged, token: settingsObserver)
            }
            settingsObserver = nil
        }
        .onExitCommand {
            exitSlideshow()
        }
        .focusable()
    }

    @MainActor
    private func slideshowImages() -> [String] {
        let selected = Array(appState.selection.selectedFiles)
        if selected.count > 1 {
            let displayed = Set(appState.fileData.displayedImages)
            return selected.filter { displayed.contains($0) }.sorted()
        }
        return appState.fileData.displayedImages
    }

    @MainActor
    private func slideshowInterval() -> TimeInterval {
        let ms = appState.config.int(forKey: "slideshow_rate", default: 5000)
        return max(0.5, Double(ms) / 1000.0)
    }

    @MainActor
    private func slideshowTransitionDuration() -> TimeInterval {
        let ms = appState.config.int(forKey: "slideshow_transition_speed", default: 1300)
        return max(0.1, Double(ms) / 1000.0)
    }

    private func slideshowStatus(images: [String]) -> String {
        guard !images.isEmpty else { return "Slideshow" }
        return "Slideshow \(slideIndex + 1) / \(images.count)"
    }

    @MainActor
    private func loadCurrentImage(images: [String]) {
        guard !images.isEmpty else {
            loadedImage = nil
            return
        }
        let clamped = max(0, min(slideIndex, images.count - 1))
        slideIndex = clamped
        let path = images[clamped]
        loadedImage = NSImage(contentsOf: URL(fileURLWithPath: path))
        appState.fileData.setCurrentImagePath(path)
        withAnimation(.easeInOut(duration: slideshowTransitionDuration())) {
            imageOpacity = 1.0
        }
    }

    @MainActor
    private func advance(images: [String], transitionDuration: TimeInterval) {
        guard images.count > 1 else { return }
        let backAndForth = appState.config.bool(forKey: "slideshow_back_and_forth", default: false)
        if backAndForth {
            if slideIndex + stepDirection >= images.count || slideIndex + stepDirection < 0 {
                stepDirection *= -1
            }
            slideIndex += stepDirection
        } else {
            slideIndex = (slideIndex + 1) % images.count
        }

        withAnimation(.easeInOut(duration: transitionDuration)) {
            imageOpacity = 0.2
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + transitionDuration * 0.5) {
            loadCurrentImage(images: images)
        }
    }

    @MainActor
    private func startTimer(images: [String], interval: TimeInterval, transitionDuration: TimeInterval) {
        stopTimer()
        guard images.count > 1 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                advance(images: images, transitionDuration: transitionDuration)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor
    private func exitSlideshow() {
        stopTimer()
        appState.fileData.setViewMode(.thumbnail)
    }
}
