import Foundation

public struct AnswerStreamProjector: Sendable {
    public let answerId: String
    public let trigger: WireTrigger
    private var differ = DeltaDiffer()
    private var sentPoints: [AnswerPoint] = []
    private var status: WireAnswerStatus = .streaming

    public init(answerId: String, trigger: WireTrigger) {
        self.answerId = answerId
        self.trigger = trigger
    }

    public var state: AnswerState {
        AnswerState(answerId: answerId, trigger: trigger, status: status, text: differ.sent, points: sentPoints)
    }

    public mutating func update(accumulated: String) -> ServerEvent? {
        guard status == .streaming else { return nil }
        return project(WireTextSanitizer.sanitize(accumulated, isFinal: false))
    }

    public mutating func finish(_ outcome: WireAnswerStatus, finalText: String? = nil) -> [ServerEvent] {
        guard status == .streaming else { return [] }
        var events: [ServerEvent] = []
        let text = finalText.map { WireTextSanitizer.sanitize($0, isFinal: true) } ?? WireTextSanitizer.sanitize(differ.sent, isFinal: true)
        if let event = project(text) {
            events.append(event)
        }
        status = outcome == .streaming ? .completed : outcome
        let closed = PointSegmenter.segment(differ.sent, answerId: answerId, isFinal: true)
        let changed = changedPoints(closed)
        sentPoints = closed
        events.append(.answerDone(.init(answerId: answerId, status: status, length: differ.sent.utf16.count, points: changed.isEmpty ? nil : changed)))
        return events
    }

    private mutating func project(_ text: String) -> ServerEvent? {
        let change = differ.update(text)
        let points = PointSegmenter.segment(differ.sent, answerId: answerId, isFinal: false)
        switch change {
        case .none:
            return nil
        case .append(let offset, let appended):
            let changed = changedPoints(points)
            sentPoints = points
            return .answerDelta(.init(answerId: answerId, offset: offset, text: appended, points: changed.isEmpty ? nil : changed))
        case .replace(let full):
            sentPoints = points
            return .answerReplace(.init(answerId: answerId, text: full, points: points))
        }
    }

    private func changedPoints(_ points: [AnswerPoint]) -> [AnswerPoint] {
        points.enumerated().compactMap { index, point in
            index < sentPoints.count && sentPoints[index] == point ? nil : point
        }
    }
}
