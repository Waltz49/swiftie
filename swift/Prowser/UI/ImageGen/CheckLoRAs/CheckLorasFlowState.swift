import Foundation

@Observable
@MainActor
final class CheckLorasFlowState {
    struct ResultsPresentation: Equatable {
        let body: String
        var cancelledBanner: String?
    }

    struct PendingRun: Equatable {
        let prescan: CheckLorasPrescanResult
        let options: CheckLorasOptions
    }

    var optionsPrescan: CheckLorasPrescanResult?
    var results: ResultsPresentation?
    /// When set, overrides saved Test LoRAs options when the options dialog opens.
    var seededOptions: CheckLorasOptions?
    /// Probe run starts only after the options window has closed (avoids AppKit progress + dialog overlap).
    var pendingRun: PendingRun?

    func takePendingRun() -> PendingRun? {
        let run = pendingRun
        pendingRun = nil
        return run
    }
}
