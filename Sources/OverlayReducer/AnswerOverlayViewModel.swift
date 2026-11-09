import Domain
import Foundation
import Observation

@MainActor
@Observable
public final class AnswerOverlayViewModel {
    private let modeCoordinator: ModeCoordinator
    private let answersController: AnswersModeController
    private let manualAnswerTrigger: ManualAnswerTrigger

    public private(set) var state: AnswerOverlayState = .initial
    public private(set) var showNoContextToast = false
    public private(set) var captureNotice: CaptureNotice?

    private var toastTask: Task<Void, Never>?
    private var captureNoticeTask: Task<Void, Never>?

    public init(
        modeCoordinator: ModeCoordinator,
        answersController: AnswersModeController,
        manualAnswerTrigger: ManualAnswerTrigger
    ) {
        self.modeCoordinator = modeCoordinator
        self.answersController = answersController
        self.manualAnswerTrigger = manualAnswerTrigger

        Task { [weak self] in
            guard let self else { return }
            for await modeState in modeCoordinator.stateUpdates() {
                self.apply(.modeChanged(modeState.mode))
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await event in answersController.streamEvents() {
                if case .noContext = event {
                    self.flashNoContextToast()
                }
                self.apply(.answerStream(event))
            }
        }
        Task { [weak self] in
            for await notice in answersController.captureNotices() {
                self?.flashCaptureNotice(notice)
            }
        }
    }

    private func flashCaptureNotice(_ notice: CaptureNotice) {
        captureNotice = notice
        captureNoticeTask?.cancel()
        captureNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.captureNotice = nil
        }
    }

    public func forceAnswerNow() {
        guard state.visibility != .manualResponsePending, state.visibility != .streaming else { return }
        Task { [manualAnswerTrigger] in
            await manualAnswerTrigger.fire()
        }
    }

    public func showLastAnswer() {
        apply(.lastAnswerRequested)
    }

    public func resetContext() {
        let shouldDiscardAccumulatingContext = state.visibility != .completed
        apply(.contextReset)

        guard shouldDiscardAccumulatingContext else { return }
        Task { [answersController] in
            await answersController.resetContext()
        }
    }

    public func copyFinalAnswer() -> String? {
        guard state.visibility == .completed else { return nil }
        return state.text
    }

    private func apply(_ action: AnswerOverlayAction) {
        state = AnswerOverlayReducer.reduce(state, action)
    }

    private func flashNoContextToast() {
        showNoContextToast = true
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.showNoContextToast = false
        }
    }
}
