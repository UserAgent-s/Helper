import Foundation

public protocol SessionContextProviding: Sendable {
    var activeSessionID: SessionID? { get async }
    func sessionForCapture(mode: SessionSpanMode) async -> SessionID?
}
