import CompanionProtocol
import Foundation

public struct CompanionExportDocument: Sendable, Equatable {
    public let filename: String
    public let markdown: String

    public init(filename: String, markdown: String) {
        self.filename = filename
        self.markdown = markdown
    }
}

public enum CompanionExportOutcome: Sendable, Equatable {
    case document(CompanionExportDocument)
    case rejected(code: String)
}

public struct CompanionExportTicket: Sendable, Equatable {
    public let ticket: String
    public let sessionId: String
    public let expiresAt: Date
}

public struct CompanionExportTickets: Sendable {
    public static let defaultLifetime: TimeInterval = 120
    public static let defaultCapacity = 8

    private struct Entry: Sendable {
        let sessionId: String
        let deviceId: String
        let document: CompanionExportDocument
        let expiresAt: Date
    }

    public let lifetime: TimeInterval
    public let capacity: Int
    private let random: any CompanionRandomSource
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    public init(lifetime: TimeInterval = defaultLifetime, capacity: Int = defaultCapacity, random: any CompanionRandomSource = SystemCompanionRandom()) {
        self.lifetime = lifetime
        self.capacity = capacity
        self.random = random
    }

    public var count: Int { entries.count }

    public mutating func issue(sessionId: String, deviceId: String, document: CompanionExportDocument, now: Date) -> CompanionExportTicket {
        purge(now: now)
        let ticket = CompanionSecrets.base64URL(random.bytes(count: CompanionSecrets.tokenByteCount))
        let key = CompanionSecrets.sha256Hex(ticket)
        let expiresAt = now.addingTimeInterval(lifetime)
        entries[key] = Entry(sessionId: sessionId, deviceId: deviceId, document: document, expiresAt: expiresAt)
        order.append(key)
        while order.count > capacity {
            entries[order.removeFirst()] = nil
        }
        return CompanionExportTicket(ticket: ticket, sessionId: sessionId, expiresAt: expiresAt)
    }

    public mutating func redeem(sessionId: String, ticket: String, now: Date) -> CompanionExportDocument? {
        purge(now: now)
        guard !ticket.isEmpty, ticket.utf8.count <= CompanionLimits.maxTokenLength else { return nil }
        let key = CompanionSecrets.sha256Hex(ticket)
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        order.removeAll { $0 == key }
        guard CompanionSecrets.constantTimeEquals(entry.sessionId, sessionId) else { return nil }
        return entry.document
    }

    public mutating func revoke(deviceId: String?) {
        let revoked = entries.filter { deviceId == nil || $0.value.deviceId == deviceId }.map(\.key)
        for key in revoked { entries[key] = nil }
        order.removeAll { entries[$0] == nil }
    }

    private mutating func purge(now: Date) {
        let expired = entries.filter { $0.value.expiresAt <= now }.map(\.key)
        guard !expired.isEmpty else { return }
        for key in expired { entries[key] = nil }
        order.removeAll { entries[$0] == nil }
    }
}
