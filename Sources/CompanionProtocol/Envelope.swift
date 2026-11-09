import Foundation

public enum CompanionProtocolVersion {
    public static let current = 1
    public static let minimumClient = 1
}

public enum CompanionLimits {
    public static let maxInboundFrameBytes = 64 * 1024
    public static let maxOutboundFrameBytes = 1024 * 1024
    public static let maxFreeTextLength = 4000
    public static let maxCommandIDLength = 64
    public static let maxIdentifierLength = 128
    public static let maxTokenLength = 256
    public static let maxPairingCodeLength = 64
    public static let maxDeviceNameLength = 64
    public static let maxSessionTitleLength = 200
    public static let maxCommandNameLength = 64
}

public enum CompanionProtocolError: Error, Sendable, Equatable {
    case frameTooLarge(bytes: Int, limit: Int)
    case unsupportedVersion(Int)
    case malformed(String)
    case invalidArgument(field: String, reason: String)

    public var code: String {
        switch self {
        case .frameTooLarge: "frame_too_large"
        case .unsupportedVersion: "unsupported_version"
        case .malformed: "malformed"
        case .invalidArgument: "invalid_argument"
        }
    }
}

public struct ServerEnvelope: Sendable, Equatable {
    public let v: Int
    public let seq: Int
    public let ts: Int64
    public let sid: String?
    public let event: ServerEvent

    public init(seq: Int, ts: Int64, sid: String? = nil, event: ServerEvent) {
        self.v = CompanionProtocolVersion.current
        self.seq = seq
        self.ts = ts
        self.sid = sid
        self.event = event
    }

    public var type: String { event.type }
}

extension ServerEnvelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case v, seq, ts, type, sid, data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .v)
        guard version == CompanionProtocolVersion.current else {
            throw CompanionProtocolError.unsupportedVersion(version)
        }
        v = version
        seq = try container.decode(Int.self, forKey: .seq)
        ts = try container.decode(Int64.self, forKey: .ts)
        sid = try container.decodeIfPresent(String.self, forKey: .sid)
        let type = try container.decode(String.self, forKey: .type)
        event = try ServerEvent.decode(type: type, from: container, key: .data)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(seq, forKey: .seq)
        try container.encode(ts, forKey: .ts)
        try container.encode(event.type, forKey: .type)
        try container.encodeIfPresent(sid, forKey: .sid)
        try event.encodeData(into: &container, key: .data)
    }
}

public enum CompanionCodec {
    public static func encode(_ envelope: ServerEnvelope) throws -> Data {
        try encodeChecked(envelope, limit: CompanionLimits.maxOutboundFrameBytes)
    }

    public static func encode(_ command: ClientCommand) throws -> Data {
        try encodeChecked(command, limit: CompanionLimits.maxInboundFrameBytes)
    }

    public static func decodeServer(_ data: Data) throws -> ServerEnvelope {
        try decodeChecked(ServerEnvelope.self, data, limit: CompanionLimits.maxOutboundFrameBytes)
    }

    public static func decodeCommand(_ data: Data) throws -> ClientCommand {
        let command = try decodeChecked(ClientCommand.self, data, limit: CompanionLimits.maxInboundFrameBytes)
        try command.validate()
        return command
    }

    public static func decodeCommand(_ text: String) throws -> ClientCommand {
        try decodeCommand(Data(text.utf8))
    }

    private static func encodeChecked(_ value: some Encodable, limit: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= limit else {
            throw CompanionProtocolError.frameTooLarge(bytes: data.count, limit: limit)
        }
        return data
    }

    private static func decodeChecked<T: Decodable>(_ type: T.Type, _ data: Data, limit: Int) throws -> T {
        guard data.count <= limit else {
            throw CompanionProtocolError.frameTooLarge(bytes: data.count, limit: limit)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as CompanionProtocolError {
            throw error
        } catch let DecodingError.keyNotFound(key, _) {
            throw CompanionProtocolError.malformed("missing \(key.stringValue)")
        } catch let DecodingError.typeMismatch(_, context) {
            throw CompanionProtocolError.malformed("type mismatch at \(context.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch let DecodingError.valueNotFound(_, context) {
            throw CompanionProtocolError.malformed("null at \(context.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch let DecodingError.dataCorrupted(context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw CompanionProtocolError.malformed(path.isEmpty ? "invalid json" : "invalid value at \(path)")
        } catch {
            throw CompanionProtocolError.malformed("invalid frame")
        }
    }
}
