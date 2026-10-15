public enum AppMode: Sendable, Equatable, CaseIterable {
    case passive
    case answers
    case recording
}

public enum ModeTransitionResult: Sendable, Equatable {
    case succeeded(AppMode)
    case failedToPassive(reason: String)
}

public protocol ModeControlling: Sendable {
    var currentMode: AppMode { get async }
    func requestTransition(to mode: AppMode) async -> ModeTransitionResult
}
