import Foundation

public protocol SessionContextProviding: Sendable {
    var activeSessionID: SessionID? { get async }
}
