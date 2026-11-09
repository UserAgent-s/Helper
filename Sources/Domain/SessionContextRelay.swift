import Foundation

public actor SessionContextRelay: SessionContextProviding {
    private var target: (any SessionContextProviding)?

    public init() {}

    public func bind(_ target: any SessionContextProviding) {
        self.target = target
    }

    public var activeSessionID: SessionID? {
        get async { await target?.activeSessionID }
    }

    public func sessionForCapture(mode: SessionSpanMode) async -> SessionID? {
        await target?.sessionForCapture(mode: mode)
    }
}
