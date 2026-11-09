import Observation

@MainActor
@Observable
final class AppNavigationState {
    var isShowingHistory = false
    var isShowingSettings = false
    var isShowingOnboarding = false
    var isShowingPairing = false
    private var pairingRequestPending = false

    func requestPairing() {
        pairingRequestPending = true
        isShowingPairing = true
    }

    func markPairingRequested() {
        pairingRequestPending = true
    }

    func consumePairingRequest() -> Bool {
        defer { pairingRequestPending = false }
        return pairingRequestPending
    }
}
