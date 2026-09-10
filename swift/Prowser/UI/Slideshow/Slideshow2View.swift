import AppKit
import SwiftUI

/// Panning slideshow (mode 2). Simplified port of `slideshow2_manager.py`.
struct Slideshow2View: View {
    @Environment(AppState.self) private var appState

    @State private var slideIndex = 0
    @State private var loadedImage: NSImage?
    @State private var panOffset = CGSize.zero
    @State private var panTarget = CGSize.zero
    @State private var timer: Timer?

    var body: some View {
        let images = slideshowImages()
        let enlargement = max(1.0, appState.config.double(forKey: "slideshow2_enlargement", default: 1.2))

        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                if let loadedImage {
                    Image(nsImage: loadedImage)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(enlargement)
                        .offset(panOffset)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    Text("No images to show")
                        .foregroundStyle(.white.opacity(0.7))
                }

                VStack {
                    Spacer()
                    HStack {
                        Text("Panning \(slideIndex + 1) / \(max(images.count, 1))")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Button("Exit (Esc)") { exitSlideshow() }
                    }
                    .padding()
                    .background(.black.opacity(0.35))
                }
            }
        }
        .onAppear {
            slideIndex = appState.fileData.currentIndex
            loadSlide(images: images, viewport: nil)
            startPanTimer(images: images)
        }
        .onChange(of: appState.fileData.currentIndex) { _, newIndex in
            slideIndex = newIndex
            loadSlide(images: slideshowImages(), viewport: nil)
        }
        .onDisappear { stopTimer() }
        .onExitCommand { exitSlideshow() }
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
    private func panInterval() -> TimeInterval {
        let speed = appState.config.int(forKey: "slideshow2_speed", default: 8)
        return max(2.0, Double(speed))
    }

    @MainActor
    private func loadSlide(images: [String], viewport: CGSize?) {
        guard !images.isEmpty else {
            loadedImage = nil
            return
        }
        let clamped = max(0, min(slideIndex, images.count - 1))
        slideIndex = clamped
        let path = images[clamped]
        loadedImage = NSImage(contentsOf: URL(fileURLWithPath: path))
        appState.fileData.setCurrentIndex(clamped)
        appState.fileData.setCurrentImagePath(path)

        let w = viewport?.width ?? 800
        let h = viewport?.height ?? 600
        panOffset = CGSize(width: -w * 0.1, height: -h * 0.1)
        panTarget = CGSize(width: w * 0.1, height: h * 0.1)
        withAnimation(.linear(duration: panInterval())) {
            panOffset = panTarget
        }
    }

    @MainActor
    private func advance(images: [String]) {
        guard images.count > 1 else { return }
        slideIndex = (slideIndex + 1) % images.count
        loadSlide(images: images, viewport: nil)
    }

    @MainActor
    private func startPanTimer(images: [String]) {
        stopTimer()
        guard images.count >= 1 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: panInterval(), repeats: true) { _ in
            Task { @MainActor in advance(images: images) }
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
