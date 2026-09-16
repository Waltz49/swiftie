import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension AppState {
    func decreaseSlideshowOverlap() {
        let transition = config.int(forKey: "slideshow_transition_speed", default: 1300)
        let current = config.int(forKey: "slideshow_overlap_delay", default: 0)
        let next = min(Int(Double(transition) * 1.0), current + Int(Double(transition) * 0.1))
        config.updateSetting("slideshow_overlap_delay", value: next)
        config.applySettingsChange(emit: eventBus)
        showSlideshowOverlapStatus(transition: transition, delay: next)
    }

    func increaseSlideshowOverlap() {
        let transition = config.int(forKey: "slideshow_transition_speed", default: 1300)
        let current = config.int(forKey: "slideshow_overlap_delay", default: 0)
        let next = max(-Int(Double(transition) * 0.3), current - Int(Double(transition) * 0.1))
        config.updateSetting("slideshow_overlap_delay", value: next)
        config.applySettingsChange(emit: eventBus)
        showSlideshowOverlapStatus(transition: transition, delay: next)
    }

    func applySlideshowPreset(_ key: String) {
        let preset = SlideshowPresetUtils.preset(from: config.rawSettings(), key: key)
        config.updateSetting("slideshow_rate", value: preset["rate"] as? Int ?? 3500)
        config.updateSetting("slideshow_transition_speed", value: preset["transition_speed"] as? Int ?? 1300)
        config.updateSetting("slideshow_max_rotation", value: preset["max_rotation"] as? Int ?? 0)
        config.updateSetting("slideshow_overlap_delay", value: preset["overlap_delay"] as? Int ?? 0)
        config.updateSetting("slideshow_direction", value: preset["direction"] as? String ?? "right")
        config.applySettingsChange(emit: eventBus)
        status.show(SlideshowPresetUtils.statusMessage(for: preset))
    }

    private func showSlideshowOverlapStatus(transition: Int, delay: Int) {
        let percent = SlideshowPresetUtils.overlapPercent(overlapDelay: delay, transitionSpeed: transition)
        if percent > 100 {
            status.show("Overlap: \(percent)% (incoming early)")
        } else {
            status.show("Overlap: \(percent)%")
        }
    }
    func fitSlideshow2ToCanvasWidth() {
        guard fileData.currentViewMode == .slideshow2,
              let path = fileData.currentImagePath,
              let image = NSImage(contentsOfFile: path) else { return }
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let viewport = slideshow2ViewportSize
        guard viewport.width > 1, viewport.height > 1 else { return }

        let widthScale = (viewport.width * 1.5) / imageSize.width
        let heightScale = (viewport.height * 1.5) / imageSize.height
        let baseScale = max(widthScale, heightScale)
        guard baseScale > 0 else { return }

        let targetScale = viewport.width / imageSize.width
        let newEnlargement = min(3.0, max(0.5, targetScale / baseScale))
        config.updateSetting("slideshow2_enlargement", value: newEnlargement)
        config.applySettingsChange(emit: eventBus)
        status.show(String(format: "Panning zoom: %.1fx (fit width)", newEnlargement))
    }
    func openBrowseFromSlideshow() {
        fileData.setViewMode(.browse)
    }

    func adjustSlideshowRate(slower: Bool) {
        let rateMS = config.int(forKey: "slideshow_rate", default: 5000)
        let newRateMS: Int
        if rateMS < 1000 {
            let rateSec = Double(rateMS) / 1000.0
            let step = slower ? 0.125 : -0.125
            newRateMS = Int(round(min(10.0, max(0.0, rateSec + step)) * 1000))
        } else {
            newRateMS = slower ? min(60_000, rateMS + 1000) : max(0, rateMS - 1000)
        }
        config.updateSetting("slideshow_rate", value: newRateMS)
        config.applySettingsChange(emit: eventBus)
        let sec = Double(newRateMS) / 1000.0
        status.show(sec >= 1.0 ? "Slideshow rate: \(sec)s" : "Slideshow rate: \(newRateMS)ms")
    }

    func adjustSlideshowTransitionSpeed(slower: Bool) {
        let current = config.int(forKey: "slideshow_transition_speed", default: 1300)
        let next = slower ? min(6000, current + 100) : max(0, current - 100)
        config.updateSetting("slideshow_transition_speed", value: next)
        config.applySettingsChange(emit: eventBus)
        status.show("Transition speed: \(next)ms")
    }

    func adjustSlideshowMaxRotation(increase: Bool) {
        let current = config.int(forKey: "slideshow_max_rotation", default: 0)
        let next = increase ? min(360, current + 5) : max(0, current - 5)
        config.updateSetting("slideshow_max_rotation", value: next)
        config.applySettingsChange(emit: eventBus)
        status.show("Max rotation: \(next)°")
    }

    func setSlideshowDirection(_ direction: String) {
        config.updateSetting("slideshow_direction", value: direction)
        config.applySettingsChange(emit: eventBus)
        let label: String
        switch direction {
        case "left": label = "From left"
        case "right": label = "From right"
        case "top": label = "From top"
        case "bottom": label = "From bottom"
        case "random": label = "Random"
        case "none": label = "None (no transition)"
        default: label = direction
        }
        status.show("Slideshow direction: \(label)")
    }

    func slideshowDirectionAdvanceIfMatches(_ direction: String) -> Bool {
        let current = config.string(forKey: "slideshow_direction", default: "right")
        if current == direction {
            slideshowStep(delta: 1)
            return true
        }
        setSlideshowDirection(direction)
        return true
    }
    func startSlideshow(_ mode: ViewMode) {
        guard !fileData.displayedImages.isEmpty else { return }
        if fileData.currentViewMode == mode {
            fileData.setViewMode(.thumbnail)
        } else {
            fileData.setViewMode(mode)
        }
    }

    func slideshowStep(delta: Int) {
        let images = fileData.displayedImages
        guard !images.isEmpty else { return }
        let wrap = config.bool(forKey: "wrap_around", default: true)
        let next = nextSlideshowIndex(fileData.currentIndex + delta, count: images.count, wrap: wrap)
        fileData.setCurrentIndex(next)
        fileData.setCurrentImagePath(images[next])
    }

    private func nextSlideshowIndex(_ raw: Int, count: Int, wrap: Bool) -> Int {
        guard count > 0 else { return 0 }
        if wrap { return ((raw % count) + count) % count }
        return min(max(0, raw), count - 1)
    }
}
