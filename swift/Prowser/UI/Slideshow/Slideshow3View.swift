import AppKit
import SwiftUI

/// Floating frames slideshow (mode 3). Simplified port of `slideshow3_manager.py`.
struct Slideshow3View: View {
    @Environment(AppState.self) private var appState

    @State private var frames: [FloatingFrame] = []
    @State private var timer: Timer?
    @State private var spawnAccumulator: TimeInterval = 0
    @State private var viewportSize: CGSize = .zero

    private let maxFrames = 8
    private let spawnInterval: TimeInterval = 1.2

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                ForEach(frames) { frame in
                    FloatingFrameView(path: frame.path, size: frame.size, rotation: frame.rotation)
                        .position(frame.position)
                }
            }
            .onAppear {
                viewportSize = geometry.size
                seedFrames(in: geometry.size)
                startAnimation()
            }
            .onChange(of: geometry.size) { _, newSize in
                viewportSize = newSize
            }
            .onDisappear { stopAnimation() }
            .onExitCommand { exitSlideshow() }
            .focusable()
        }
    }

    @MainActor
    private func slideshowImages() -> [String] {
        let selected = Array(appState.selection.selectedFiles)
        if selected.count > 1 {
            let displayed = Set(appState.fileData.displayedImages)
            return selected.filter { displayed.contains($0) }
        }
        return appState.fileData.displayedImages
    }

    @MainActor
    private func seedFrames(in size: CGSize) {
        let images = slideshowImages()
        guard !images.isEmpty else { return }
        frames = (0..<min(3, images.count)).map { index in
            makeFrame(path: images[index % images.count], in: size, randomStart: true)
        }
    }

    @MainActor
    private func startAnimation() {
        stopAnimation()
        guard !slideshowImages().isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in tick() }
        }
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor
    private func tick() {
        let images = slideshowImages()
        guard !images.isEmpty, viewportSize.width > 0 else { return }
        let dt = 1.0 / 60.0
        spawnAccumulator += dt

        if spawnAccumulator >= spawnInterval, frames.count < maxFrames {
            spawnAccumulator = 0
            let path = images.randomElement() ?? images[0]
            frames.append(makeFrame(path: path, in: viewportSize, randomStart: true))
        }

        for index in frames.indices {
            frames[index].position.x += frames[index].velocity.dx * dt
            frames[index].position.y += frames[index].velocity.dy * dt
            frames[index].rotation += frames[index].spin * dt
        }

        let margin: CGFloat = 120
        frames.removeAll { frame in
            frame.position.x < -margin
                || frame.position.x > viewportSize.width + margin
                || frame.position.y < -margin
                || frame.position.y > viewportSize.height + margin
        }
    }

    private func makeFrame(path: String, in size: CGSize, randomStart: Bool) -> FloatingFrame {
        let frameSize = CGFloat.random(in: 120...220)
        let startX = randomStart ? CGFloat.random(in: 0...size.width) : -frameSize
        let startY = CGFloat.random(in: frameSize...max(frameSize, size.height - frameSize))
        let speed = CGFloat.random(in: 40...90)
        let angle = CGFloat.random(in: -0.4...0.4)
        return FloatingFrame(
            path: path,
            position: CGPoint(x: startX, y: startY),
            size: frameSize,
            velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed * 0.35),
            rotation: Double.random(in: -12...12),
            spin: Double.random(in: -8...8)
        )
    }

    @MainActor
    private func exitSlideshow() {
        stopAnimation()
        appState.fileData.setViewMode(.thumbnail)
    }
}

private struct FloatingFrame: Identifiable {
    let id = UUID()
    let path: String
    var position: CGPoint
    let size: CGFloat
    let velocity: CGVector
    var rotation: Double
    let spin: Double
}

private struct FloatingFrameView: View {
    @Environment(AppState.self) private var appState

    let path: String
    let size: CGFloat
    let rotation: Double

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: 0.55, green: 0.35, blue: 0.17))
                .frame(width: size + 12, height: size + 12)
                .shadow(radius: 6)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.35))
                    .frame(width: size, height: size)
            }
        }
        .rotationEffect(.degrees(rotation))
        .task(id: path) {
            let pixelSize = Int(size * 2)
            if let cg = await appState.thumbnailCache.generateThumbnail(for: path, size: pixelSize) {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            } else if let loaded = NSImage(contentsOfFile: path) {
                image = loaded
            }
        }
    }
}
