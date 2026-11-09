import Foundation

public enum RealtimeClientEvent: Encodable, Sendable {
    case sessionUpdate(SessionConfig)
    case inputAudioBufferAppend(audioBase64: String)
    case responseCreate(ResponseCreateOptions)
    case responseCancel
    case conversationItemDelete(itemID: String)
    case conversationItemCreate(ConversationItemPayload)
    case inputAudioBufferClear
    case inputAudioBufferCommit
    case transcriptionSessionUpdate(TranscriptionSessionConfig)

    private enum CodingKeys: String, CodingKey {
        case type, session, audio, response, item
        case itemID = "item_id"
        case previousItemID = "previous_item_id"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sessionUpdate(let session):
            try container.encode("session.update", forKey: .type)
            try container.encode(session, forKey: .session)
        case .inputAudioBufferAppend(let audioBase64):
            try container.encode("input_audio_buffer.append", forKey: .type)
            try container.encode(audioBase64, forKey: .audio)
        case .responseCreate(let options):
            try container.encode("response.create", forKey: .type)
            try container.encode(options, forKey: .response)
        case .responseCancel:
            try container.encode("response.cancel", forKey: .type)
        case .conversationItemDelete(let itemID):
            try container.encode("conversation.item.delete", forKey: .type)
            try container.encode(itemID, forKey: .itemID)
        case .conversationItemCreate(let payload):
            try container.encode("conversation.item.create", forKey: .type)
            try container.encode(payload, forKey: .item)
            try container.encodeIfPresent(payload.previousItemID, forKey: .previousItemID)
        case .inputAudioBufferClear:
            try container.encode("input_audio_buffer.clear", forKey: .type)
        case .inputAudioBufferCommit:
            try container.encode("input_audio_buffer.commit", forKey: .type)
        case .transcriptionSessionUpdate(let session):
            try container.encode("session.update", forKey: .type)
            try container.encode(session, forKey: .session)
        }
    }
}

public struct TranscriptionSessionConfig: Encodable, Sendable, Equatable {
    let model: String
    let rate: Int
    let languages: [String]
    let delay: String

    private enum CodingKeys: String, CodingKey { case type, audio }
    private enum AudioKeys: String, CodingKey { case input }
    private enum InputKeys: String, CodingKey {
        case format, transcription
        case turnDetection = "turn_detection"
    }
    private enum TranscriptionKeys: String, CodingKey { case model, languages, delay }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("transcription", forKey: .type)
        var audio = container.nestedContainer(keyedBy: AudioKeys.self, forKey: .audio)
        var input = audio.nestedContainer(keyedBy: InputKeys.self, forKey: .input)
        try input.encode(AudioFormatConfig(rate: rate), forKey: .format)
        var transcription = input.nestedContainer(keyedBy: TranscriptionKeys.self, forKey: .transcription)
        try transcription.encode(model, forKey: .model)
        if !languages.isEmpty {
            try transcription.encode(languages, forKey: .languages)
        }
        try transcription.encode(delay, forKey: .delay)
        try input.encodeNil(forKey: .turnDetection)
    }
}

public enum ConversationItemRole: String, Encodable, Sendable {
    case system, user
}

public struct ConversationItemPayload: Encodable, Sendable, Equatable {
    let id: String
    let role: ConversationItemRole
    let text: String
    let previousItemID: String?

    init(id: String, role: ConversationItemRole, text: String, previousItemID: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.previousItemID = previousItemID
    }

    private struct Content: Encodable {
        let type = "input_text"
        let text: String
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, role, content
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode("message", forKey: .type)
        try container.encode(role, forKey: .role)
        try container.encode([Content(text: text)], forKey: .content)
    }
}

public struct SessionConfig: Encodable, Sendable {
    var type = "realtime"
    let model: String
    let instructions: String
    let outputModalities: [String]
    let audio: AudioConfig
    let reasoning: ReasoningConfig

    enum CodingKeys: String, CodingKey {
        case type, model, instructions, audio, reasoning
        case outputModalities = "output_modalities"
    }
}

struct ReasoningConfig: Encodable, Sendable {
    let effort: String
}

struct AudioConfig: Encodable, Sendable {
    let input: AudioInputConfig
}

struct AudioInputConfig: Encodable, Sendable {
    let format: AudioFormatConfig
    let turnDetection: TurnDetectionConfig
    var transcription: InputTranscriptionConfig?

    enum CodingKeys: String, CodingKey {
        case format, transcription
        case turnDetection = "turn_detection"
    }
}

struct InputTranscriptionConfig: Encodable, Sendable, Equatable {
    let model: String
    let languages: [String]?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        if let languages, !languages.isEmpty {
            try container.encode(languages, forKey: .languages)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case model, languages
    }
}

struct AudioFormatConfig: Encodable, Sendable {
    var type = "audio/pcm"
    let rate: Int
}

struct TurnDetectionConfig: Encodable, Sendable {
    var type = "server_vad"
    let threshold: Double
    let prefixPaddingMs: Int
    let silenceDurationMs: Int
    let createResponse: Bool
    let interruptResponse: Bool

    enum CodingKeys: String, CodingKey {
        case type, threshold
        case prefixPaddingMs = "prefix_padding_ms"
        case silenceDurationMs = "silence_duration_ms"
        case createResponse = "create_response"
        case interruptResponse = "interrupt_response"
    }

    static let `default` = TurnDetectionConfig(
        threshold: 0.5,
        prefixPaddingMs: 300,
        silenceDurationMs: 300,
        createResponse: true,
        interruptResponse: true
    )
}

public struct RealtimeVADSettings: Sendable, Equatable {
    public var threshold: Double
    public var prefixPaddingMs: Int
    public var silenceDurationMs: Int

    public init(threshold: Double = 0.5, prefixPaddingMs: Int = 300, silenceDurationMs: Int = 300) {
        self.threshold = threshold
        self.prefixPaddingMs = prefixPaddingMs
        self.silenceDurationMs = silenceDurationMs
    }

    public static let safeDefault = RealtimeVADSettings()

    var config: TurnDetectionConfig {
        TurnDetectionConfig(
            threshold: threshold,
            prefixPaddingMs: prefixPaddingMs,
            silenceDurationMs: silenceDurationMs,
            createResponse: true,
            interruptResponse: true
        )
    }
}

public struct ResponseCreateOptions: Encodable, Sendable {
    let instructions: String?
    let outputModalities: [String]
    let metadata: [String: String]?

    enum CodingKeys: String, CodingKey {
        case instructions, metadata
        case outputModalities = "output_modalities"
    }
}

public enum RealtimeServerEvent: Sendable, Equatable {
    case sessionCreated
    case sessionUpdated
    case speechStarted(itemID: String, audioStartMs: Int)
    case speechStopped(itemID: String, audioEndMs: Int)
    case inputAudioBufferCommitted(itemID: String, previousItemID: String?)
    case conversationItemCreated(itemID: String, previousItemID: String?)
    case responseCreated(responseID: String, metadata: [String: String]? = nil)
    case outputTextDelta(responseID: String, itemID: String, delta: String)
    case outputTextDone(responseID: String, itemID: String, text: String)
    case responseDone(responseID: String, status: String, outputItemIDs: [String])
    case inputAudioTranscriptionDelta(itemID: String, delta: String)
    case inputAudioTranscriptionCompleted(itemID: String, transcript: String, language: String?)
    case inputAudioTranscriptionFailed(itemID: String, message: String?)
    case rateLimitsUpdated
    case error(message: String, code: String?)
    case unknown(type: String)
}

enum RealtimeServerEventDecoder {
    static func decode(_ data: Data) -> RealtimeServerEvent {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            return .unknown(type: "undecodable")
        }

        switch envelope.type {
        case "session.created":
            return .sessionCreated
        case "session.updated":
            return .sessionUpdated
        case "input_audio_buffer.speech_started":
            guard let p = try? decoder.decode(SpeechStartedPayload.self, from: data) else { return .unknown(type: envelope.type) }
            return .speechStarted(itemID: p.itemID, audioStartMs: p.audioStartMs)
        case "input_audio_buffer.speech_stopped":
            guard let p = try? decoder.decode(SpeechStoppedPayload.self, from: data) else { return .unknown(type: envelope.type) }
            return .speechStopped(itemID: p.itemID, audioEndMs: p.audioEndMs)
        case "input_audio_buffer.committed":
            guard let p = try? decoder.decode(CommittedPayload.self, from: data) else { return .unknown(type: envelope.type) }
            return .inputAudioBufferCommitted(itemID: p.itemID, previousItemID: p.previousItemID)
        case "conversation.item.created", "conversation.item.added", "conversation.item.done":
            guard let p = try? decoder.decode(ConversationItemCreatedPayload.self, from: data) else { return .unknown(type: envelope.type) }
            return .conversationItemCreated(itemID: p.item.id, previousItemID: p.previousItemID)
        case "response.created":
            guard let p = try? decoder.decode(ResponseCreatedPayload.self, from: data) else { return .unknown(type: envelope.type) }
            return .responseCreated(responseID: p.response.id, metadata: p.response.metadata)
        case "response.output_text.delta":
            guard let p = try? decoder.decode(OutputTextDeltaPayload.self, from: data) else { return .unknown(type: envelope.type) }
            return .outputTextDelta(responseID: p.responseID, itemID: p.itemID, delta: p.delta)
        case "response.output_text.done":
            guard let p = try? decoder.decode(OutputTextDonePayload.self, from: data) else { return .unknown(type: envelope.type) }
            return .outputTextDone(responseID: p.responseID, itemID: p.itemID, text: p.text)
        case "response.done":
            guard let p = try? decoder.decode(ResponseDonePayload.self, from: data) else { return .unknown(type: envelope.type) }
            return .responseDone(responseID: p.response.id, status: p.response.status, outputItemIDs: (p.response.output ?? []).map(\.id))
        case "conversation.item.input_audio_transcription.delta":
            guard let p = try? decoder.decode(TranscriptionDeltaPayload.self, from: data) else { return .unknown(type: envelope.type) }
            return .inputAudioTranscriptionDelta(itemID: p.itemID, delta: p.delta ?? "")
        case "conversation.item.input_audio_transcription.completed":
            guard let p = try? decoder.decode(TranscriptionCompletedPayload.self, from: data) else { return .unknown(type: envelope.type) }
            return .inputAudioTranscriptionCompleted(itemID: p.itemID, transcript: p.transcript, language: p.languages?.first?.code)
        case "conversation.item.input_audio_transcription.failed":
            guard let p = try? decoder.decode(TranscriptionFailedPayload.self, from: data) else { return .unknown(type: envelope.type) }
            return .inputAudioTranscriptionFailed(itemID: p.itemID, message: p.error?.message)
        case "rate_limits.updated":
            return .rateLimitsUpdated
        case "error":
            guard let p = try? decoder.decode(ErrorPayload.self, from: data) else { return .unknown(type: envelope.type) }
            return .error(message: p.error.message, code: p.error.code)
        default:
            return .unknown(type: envelope.type)
        }
    }

    private struct Envelope: Decodable { let type: String }

    private struct SpeechStartedPayload: Decodable {
        let itemID: String
        let audioStartMs: Int
        enum CodingKeys: String, CodingKey { case itemID = "item_id", audioStartMs = "audio_start_ms" }
    }

    private struct SpeechStoppedPayload: Decodable {
        let itemID: String
        let audioEndMs: Int
        enum CodingKeys: String, CodingKey { case itemID = "item_id", audioEndMs = "audio_end_ms" }
    }

    private struct CommittedPayload: Decodable {
        let itemID: String
        let previousItemID: String?
        enum CodingKeys: String, CodingKey { case itemID = "item_id", previousItemID = "previous_item_id" }
    }

    private struct ConversationItemCreatedPayload: Decodable {
        struct Item: Decodable { let id: String }
        let item: Item
        let previousItemID: String?
        enum CodingKeys: String, CodingKey { case item, previousItemID = "previous_item_id" }
    }

    private struct ResponseCreatedPayload: Decodable {
        struct ResponseObject: Decodable { let id: String; let metadata: [String: String]? }
        let response: ResponseObject
    }

    private struct OutputTextDeltaPayload: Decodable {
        let responseID: String
        let itemID: String
        let delta: String
        enum CodingKeys: String, CodingKey { case responseID = "response_id", itemID = "item_id", delta }
    }

    private struct OutputTextDonePayload: Decodable {
        let responseID: String
        let itemID: String
        let text: String
        enum CodingKeys: String, CodingKey { case responseID = "response_id", itemID = "item_id", text }
    }

    private struct ResponseDonePayload: Decodable {
        struct OutputItem: Decodable { let id: String }
        struct ResponseObject: Decodable {
            let id: String
            let status: String
            let output: [OutputItem]?
        }
        let response: ResponseObject
    }

    private struct TranscriptionDeltaPayload: Decodable {
        let itemID: String
        let delta: String?
        enum CodingKeys: String, CodingKey { case itemID = "item_id", delta }
    }

    private struct TranscriptionCompletedPayload: Decodable {
        struct Language: Decodable { let code: String }
        let itemID: String
        let transcript: String
        let languages: [Language]?
        enum CodingKeys: String, CodingKey { case itemID = "item_id", transcript, languages }
    }

    private struct TranscriptionFailedPayload: Decodable {
        struct Detail: Decodable { let message: String? }
        let itemID: String
        let error: Detail?
        enum CodingKeys: String, CodingKey { case itemID = "item_id", error }
    }

    private struct ErrorPayload: Decodable {
        struct ErrorDetail: Decodable { let message: String; let code: String? }
        let error: ErrorDetail
    }
}
