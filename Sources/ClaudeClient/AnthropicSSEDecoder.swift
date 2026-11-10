import Foundation

public struct AnthropicSSEDecoder: Sendable {
    private var messageID = ""
    private var model = ""
    private var usage = ClaudeUsage()
    private var text = ""
    private var textBlocks: Set<Int> = []
    private var stopReason: String?
    private var stopCategory: String?
    private var stopExplanation: String?
    private var finished = false

    public init() {}

    public var isFinished: Bool { finished }

    public mutating func consume(line rawLine: String) -> [ClaudeStreamEvent] {
        guard !finished else { return [] }
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        guard line.hasPrefix("data:") else { return [] }
        var payload = line.dropFirst(5)
        if payload.first == " " { payload = payload.dropFirst() }
        guard !payload.isEmpty else { return [] }
        let data = Data(payload.utf8)
        let envelope: WireEnvelope
        do {
            envelope = try JSONDecoder().decode(WireEnvelope.self, from: data)
        } catch {
            return terminate(.failed(.malformed("undecodable event")))
        }
        switch envelope.type {
        case "message_start":
            guard let message = envelope.message else { return terminate(.failed(.malformed("message_start without message"))) }
            messageID = message.id ?? ""
            model = message.model ?? ""
            if let wire = message.usage { usage.merge(wire) }
            return [.started(messageID: messageID, model: model, usage: usage)]
        case "content_block_start":
            guard let index = envelope.index, let block = envelope.contentBlock else { return [] }
            switch block.type {
            case "text":
                textBlocks.insert(index)
                if let initial = block.text, !initial.isEmpty {
                    text += initial
                    return [.textDelta(initial)]
                }
                return []
            case "fallback":
                return [.fallback(fromModel: block.from?.model, toModel: block.to?.model)]
            default:
                return []
            }
        case "content_block_delta":
            guard let delta = envelope.delta, delta.type == "text_delta", let index = envelope.index, textBlocks.contains(index), let chunk = delta.text, !chunk.isEmpty else {
                return []
            }
            text += chunk
            return [.textDelta(chunk)]
        case "message_delta":
            if let reason = envelope.delta?.stopReason { stopReason = reason }
            if let details = envelope.delta?.stopDetails {
                stopCategory = details.category
                stopExplanation = details.explanation
            }
            if let wire = envelope.usage { usage.merge(wire) }
            return []
        case "message_stop":
            return terminate(finalEvent())
        case "error":
            let type = envelope.error?.type ?? "unknown_error"
            return terminate(.failed(.api(type: type, message: envelope.error?.message)))
        default:
            return []
        }
    }

    public mutating func finish() -> [ClaudeStreamEvent] {
        guard !finished else { return [] }
        return terminate(.failed(.incomplete))
    }

    private mutating func terminate(_ event: ClaudeStreamEvent) -> [ClaudeStreamEvent] {
        finished = true
        return [event]
    }

    private func finalEvent() -> ClaudeStreamEvent {
        let reason = ClaudeStopReason(wire: stopReason ?? "end_turn")
        let completion = ClaudeCompletion(messageID: messageID, model: model, text: text, stopReason: reason, usage: usage)
        switch reason {
        case .refusal:
            return .refused(ClaudeRefusal(category: stopCategory, explanation: stopExplanation, partialText: text, model: model, usage: usage))
        case .maxTokens:
            return .truncated(completion)
        default:
            return .completed(completion)
        }
    }
}

struct WireEnvelope: Decodable {
    let type: String
    let index: Int?
    let message: WireMessage?
    let contentBlock: WireContentBlock?
    let delta: WireDelta?
    let usage: WireUsage?
    let error: WireError?

    enum CodingKeys: String, CodingKey {
        case type, index, message, delta, usage, error
        case contentBlock = "content_block"
    }
}

struct WireMessage: Decodable {
    let id: String?
    let model: String?
    let usage: WireUsage?
    let content: [WireContentBlock]?
    let stopReason: String?
    let stopDetails: WireStopDetails?

    enum CodingKeys: String, CodingKey {
        case id, model, usage, content
        case stopReason = "stop_reason"
        case stopDetails = "stop_details"
    }
}

struct WireModelRef: Decodable {
    let model: String?
}

struct WireContentBlock: Decodable {
    let type: String
    let text: String?
    let from: WireModelRef?
    let to: WireModelRef?
}

struct WireDelta: Decodable {
    let type: String?
    let text: String?
    let stopReason: String?
    let stopDetails: WireStopDetails?

    enum CodingKeys: String, CodingKey {
        case type, text
        case stopReason = "stop_reason"
        case stopDetails = "stop_details"
    }
}

struct WireStopDetails: Decodable {
    let category: String?
    let explanation: String?
}

struct WireError: Decodable {
    let type: String?
    let message: String?
}

struct WireErrorBody: Decodable {
    let error: WireError?
}
