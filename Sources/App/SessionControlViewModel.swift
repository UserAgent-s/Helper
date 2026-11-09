import Domain
import Foundation
import Observation

@MainActor
@Observable
final class SessionControlViewModel {
    enum Feedback: Equatable {
        case starred
        case unstarred
        case noCompletedAnswer
        case noActiveSession
        case momentMarked
        case failed
    }

    private let sessions: any SessionControlling
    private(set) var state: SessionState = .idle
    private(set) var feedback: Feedback?
    private(set) var isBusy = false
    @ObservationIgnored private var observer: Task<Void, Never>?

    init(sessions: any SessionControlling) {
        self.sessions = sessions
        let updates = sessions.stateUpdates(subscriber: "sessionControl")
        observer = Task { [weak self] in
            for await state in updates {
                self?.state = state
            }
        }
    }

    isolated deinit {
        observer?.cancel()
    }

    var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    var startedAt: Date? {
        if case .active(_, let startedAt, _) = state { return startedAt }
        return nil
    }

    func toggle() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        switch await sessions.currentState {
        case .idle:
            await performStart()
        case .active:
            await sessions.stop()
        case .finalizing:
            return
        }
    }

    func start() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        guard case .idle = await sessions.currentState else { return }
        await performStart()
    }

    func stop() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        guard case .active = await sessions.currentState else { return }
        await sessions.stop()
    }

    func starLastAnswer() async {
        do {
            switch try await sessions.toggleStarLastAnswer() {
            case .starred: feedback = .starred
            case .unstarred: feedback = .unstarred
            case .noCompletedAnswer: feedback = .noCompletedAnswer
            case .noActiveSession: feedback = .noActiveSession
            }
        } catch {
            feedback = .failed
        }
    }

    func markMoment() async {
        do {
            feedback = try await sessions.markMoment(note: nil) == nil ? .noActiveSession : .momentMarked
        } catch {
            feedback = .failed
        }
    }

    @discardableResult
    func registerHotKeys(on controller: AnswerOverlayWindowController, preferences: OverlayPreferencesStore) -> [HotKeyRegistrationResult] {
        [
            controller.registerHotKey(preferences.toggleSessionHotKey) { [weak self] in
                Task { await self?.toggle() }
            },
            controller.registerHotKey(preferences.starLastAnswerHotKey) { [weak self] in
                Task { await self?.starLastAnswer() }
            },
        ]
    }

    private func performStart() async {
        do {
            try await sessions.start()
        } catch {
            feedback = .failed
        }
    }
}
