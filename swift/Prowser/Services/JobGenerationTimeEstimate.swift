import Foundation

/// Live remaining-time estimate for image generation (setup vs diffusion steps).
enum JobGenerationTimeEstimate {
    static func remainingSeconds(
        elapsed: Double,
        completedStep: Int,
        totalSteps: Int,
        historicalAvgTotalSeconds: Double?,
        firstStepDuration: Double?,
        interStepDurations: [Double],
        partialStepElapsed: Double? = nil
    ) -> Double? {
        guard totalSteps > 0 else { return nil }
        let step = max(0, completedStep)
        if step >= totalSteps {
            return 0
        }
        let stepsRemaining = totalSteps - step
        guard stepsRemaining > 0 else { return 0 }

        if step <= 1 {
            guard let average = historicalAvgTotalSeconds, average > 0 else { return nil }
            return max(0, average - elapsed)
        }

        let secondsPerStep: Double?
        if step < 3 {
            secondsPerStep = firstStepDuration
        } else if !interStepDurations.isEmpty {
            secondsPerStep = interStepDurations.reduce(0, +) / Double(interStepDurations.count)
        } else {
            secondsPerStep = firstStepDuration
        }

        guard let secondsPerStep, secondsPerStep > 0 else { return nil }
        let gross = secondsPerStep * Double(stepsRemaining)
        let intoCurrentStep = max(0, partialStepElapsed ?? 0)
        return max(0, gross - intoCurrentStep)
    }
}

/// Records diffusion step boundary times for ``JobGenerationTimeEstimate``.
struct JobGenerationStepTimingState {
    private(set) var firstStepDuration: Double?
    private(set) var interStepDurations: [Double] = []

    private var diffusionStepStartTime: Date?
    private var lastStepBoundaryTime: Date?

    mutating func reset() {
        firstStepDuration = nil
        interStepDurations = []
        diffusionStepStartTime = nil
        lastStepBoundaryTime = nil
    }

    func partialStepElapsed(now: Date = Date()) -> Double? {
        guard let lastStepBoundaryTime else { return nil }
        return now.timeIntervalSince(lastStepBoundaryTime)
    }

    mutating func recordStepAdvance(from previousStep: Int, to newStep: Int, now: Date = Date()) {
        guard newStep > previousStep else { return }
        var step = previousStep
        while step < newStep {
            let next = step + 1
            if next == 1 {
                diffusionStepStartTime = now
                lastStepBoundaryTime = now
            } else if next == 2 {
                if let start = diffusionStepStartTime ?? lastStepBoundaryTime {
                    firstStepDuration = now.timeIntervalSince(start)
                }
                lastStepBoundaryTime = now
            } else {
                if let last = lastStepBoundaryTime {
                    interStepDurations.append(now.timeIntervalSince(last))
                }
                lastStepBoundaryTime = now
            }
            step = next
        }
    }
}
