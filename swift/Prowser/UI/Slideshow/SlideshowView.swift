import AppKit
import SwiftUI

/// Slideshow mode 1 — timed advance with crossfade or directional slide + rotation.
struct SlideshowView: View {
    @Environment(AppState.self) private var appState

    @State private var slideIndex = 0
    @State private var stepDirection = 1
    @State private var timer: Timer?
    @State private var displayedPath: String?
    @State private var mainImage: NSImage?
    @State private var outgoingImage: NSImage?
    @State private var transitionProgress: Double = 1
    @State private var transitionOpacityOnly = true
    @State private var transitionVectors = SlideshowTransitionMath.EntryVectors(incomingStart: .zero, outgoingEnd: .zero)
    @State private var outgoingRotationEnd: Double = 0
    @State private var incomingRotationStart: Double = 0
    @State private var transitionTimer: Timer?
    @State private var transitionGeneration = 0
    @State private var activeTransitionDuration: TimeInterval = 1.3
    @State private var activeOverlapDelayMs = 0
    @State private var containerSize: CGSize = CGSize(width: 800, height: 600)
    @State private var settingsObserver: UUID?

    private var isTransitioning: Bool { outgoingImage != nil }

    var body: some View {
        let images = slideshowImages()
        let interval = slideshowInterval()

        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                if mainImage != nil || outgoingImage != nil {
                    ZStack {
                        if let outgoingImage {
                            slideLayer(
                                outgoingImage,
                                offset: outgoingOffset(progress: transitionProgress),
                                rotation: outgoingRotation(progress: transitionProgress),
                                opacity: outgoingOpacity(progress: transitionProgress)
                            )
                        }
                        if let mainImage {
                            slideLayer(
                                mainImage,
                                offset: incomingOffset(progress: transitionProgress),
                                rotation: incomingRotation(progress: transitionProgress),
                                opacity: incomingOpacity(progress: transitionProgress)
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                } else {
                    Text("No images to show")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .onAppear {
                if containerSize != geometry.size {
                    containerSize = geometry.size
                }
            }
            .onChange(of: geometry.size) { _, newSize in
                containerSize = newSize
            }
        }
        .onAppear {
            slideIndex = appState.fileData.currentIndex
            syncDisplayedImage(images: images)
            startTimer(images: images, interval: interval)
            if settingsObserver == nil {
                settingsObserver = appState.eventBus.subscribe(.settingsChanged) { _ in
                    Task { @MainActor in
                        let images = slideshowImages()
                        startTimer(images: images, interval: slideshowInterval())
                    }
                }
            }
        }
        .onChange(of: appState.fileData.currentIndex) { _, newIndex in
            slideIndex = newIndex
            guard !isTransitioning else { return }
            let images = slideshowImages()
            guard !images.isEmpty, newIndex >= 0, newIndex < images.count else { return }
            let path = images[newIndex]
            guard path != displayedPath else { return }
            runTransition(toPath: path)
        }
        .onDisappear {
            stopTransitionTimer()
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

    private func slideLayer(
        _ image: NSImage,
        offset: CGSize,
        rotation: Double,
        opacity: Double
    ) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .rotationEffect(.degrees(rotation))
            .offset(x: offset.width, y: offset.height)
            .opacity(opacity)
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
        let ms = max(0, appState.config.int(forKey: "slideshow_rate", default: 5000))
        return Double(ms) / 1000.0
    }

    @MainActor
    private func slideshowTransitionDuration() -> TimeInterval {
        let rateMs = max(0, appState.config.int(forKey: "slideshow_rate", default: 5000))
        let transitionMs = max(0, appState.config.int(forKey: "slideshow_transition_speed", default: 1300))
        let effectiveMs = SlideshowPresetUtils.effectiveTransitionSpeedMs(
            transitionSpeedMs: transitionMs,
            slideRateMs: rateMs
        )
        return Double(effectiveMs) / 1000.0
    }

    @MainActor
    private func loadImage(path: String) -> NSImage? {
        NSImage(contentsOf: URL(fileURLWithPath: path))
    }

    @MainActor
    private func stopTransitionTimer() {
        transitionTimer?.invalidate()
        transitionTimer = nil
    }

    @MainActor
    private func syncDisplayedImage(images: [String]) {
        stopTransitionTimer()
        outgoingImage = nil
        transitionProgress = 1
        guard !images.isEmpty else {
            displayedPath = nil
            mainImage = nil
            return
        }
        let clamped = max(0, min(slideIndex, images.count - 1))
        slideIndex = clamped
        let path = images[clamped]
        displayedPath = path
        mainImage = loadImage(path: path)
        appState.fileData.setCurrentImagePath(path)
    }

    @MainActor
    private func finishTransition(path: String, generation: Int) {
        guard generation == transitionGeneration else { return }
        stopTransitionTimer()
        outgoingImage = nil
        transitionProgress = 1
        displayedPath = path
        appState.fileData.setCurrentImagePath(path)
    }

    private func outgoingOffset(progress: Double) -> CGSize {
        guard !transitionOpacityOnly else { return .zero }
        let t = SlideshowTransitionMath.overlapOutgoingProgress(
            linearProgress: progress,
            overlapDelayMs: activeOverlapDelayMs,
            duration: activeTransitionDuration
        )
        let eased = SlideshowTransitionMath.easeInQuad(t)
        return SlideshowTransitionMath.lerpSize(.zero, transitionVectors.outgoingEnd, t: eased)
    }

    private func incomingOffset(progress: Double) -> CGSize {
        guard !transitionOpacityOnly else { return .zero }
        let t = SlideshowTransitionMath.overlapIncomingProgress(
            linearProgress: progress,
            overlapDelayMs: activeOverlapDelayMs,
            duration: activeTransitionDuration
        )
        let eased = SlideshowTransitionMath.easeOutQuad(t)
        return SlideshowTransitionMath.lerpSize(transitionVectors.incomingStart, .zero, t: eased)
    }

    private func outgoingRotation(progress: Double) -> Double {
        guard outgoingRotationEnd != 0, !transitionOpacityOnly else { return 0 }
        let t = SlideshowTransitionMath.overlapOutgoingProgress(
            linearProgress: progress,
            overlapDelayMs: activeOverlapDelayMs,
            duration: activeTransitionDuration
        )
        return outgoingRotationEnd * SlideshowTransitionMath.easeInQuad(t)
    }

    private func incomingRotation(progress: Double) -> Double {
        guard incomingRotationStart != 0, !transitionOpacityOnly else { return 0 }
        let t = SlideshowTransitionMath.overlapIncomingProgress(
            linearProgress: progress,
            overlapDelayMs: activeOverlapDelayMs,
            duration: activeTransitionDuration
        )
        return incomingRotationStart * (1 - SlideshowTransitionMath.easeOutQuad(t))
    }

    private func outgoingOpacity(progress: Double) -> Double {
        if transitionOpacityOnly {
            return isTransitioning ? (1 - progress) : 1
        }
        let t = SlideshowTransitionMath.overlapOutgoingProgress(
            linearProgress: progress,
            overlapDelayMs: activeOverlapDelayMs,
            duration: activeTransitionDuration
        )
        return SlideshowTransitionMath.outgoingOpacityDirectional(positionProgress: t)
    }

    private func incomingOpacity(progress: Double) -> Double {
        if transitionOpacityOnly {
            return isTransitioning ? progress : 1
        }
        return 1
    }

    @MainActor
    private func runTransition(toPath path: String) {
        guard let incoming = loadImage(path: path) else { return }

        stopTransitionTimer()
        transitionGeneration += 1
        let generation = transitionGeneration

        let duration = slideshowTransitionDuration()
        activeTransitionDuration = duration
        activeOverlapDelayMs = appState.config.int(forKey: "slideshow_overlap_delay", default: 0)
        let direction = appState.config.string(forKey: "slideshow_direction", default: "right")
        let maxRotation = appState.config.int(forKey: "slideshow_max_rotation", default: 0)
        let (vectors, opacityOnly) = SlideshowTransitionMath.entryVectorsForTransition(
            direction: direction,
            containerSize: containerSize
        )
        let rotations = SlideshowTransitionMath.rotationPair(maxRotation: maxRotation)

        transitionVectors = vectors
        transitionOpacityOnly = opacityOnly
        outgoingRotationEnd = rotations.outgoingEnd
        incomingRotationStart = rotations.incomingStart

        if duration <= 0 {
            outgoingImage = nil
            mainImage = incoming
            transitionProgress = 1
            displayedPath = path
            appState.fileData.setCurrentImagePath(path)
            return
        }

        outgoingImage = mainImage
        mainImage = incoming
        transitionProgress = 0

        let startTime = CFAbsoluteTimeGetCurrent()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard generation == transitionGeneration else {
                    timer.invalidate()
                    return
                }
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                let progress = min(1.0, elapsed / duration)
                transitionProgress = progress
                if progress >= 1 {
                    timer.invalidate()
                    transitionTimer = nil
                    finishTransition(path: path, generation: generation)
                }
            }
        }
        transitionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @MainActor
    private func advance(images: [String]) {
        guard images.count > 1 else { return }
        let backAndForth = appState.config.bool(forKey: "slideshow_back_and_forth", default: false)
        let nextIndex: Int
        if backAndForth {
            if slideIndex + stepDirection >= images.count || slideIndex + stepDirection < 0 {
                stepDirection *= -1
            }
            nextIndex = slideIndex + stepDirection
        } else {
            nextIndex = (slideIndex + 1) % images.count
        }

        let path = images[nextIndex]
        slideIndex = nextIndex
        runTransition(toPath: path)
    }

    @MainActor
    private func startTimer(images: [String], interval: TimeInterval) {
        stopTimer()
        guard images.count > 1, interval > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                advance(images: images)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor
    private func exitSlideshow() {
        stopTransitionTimer()
        stopTimer()
        appState.fileData.setViewMode(.thumbnail)
    }
}
