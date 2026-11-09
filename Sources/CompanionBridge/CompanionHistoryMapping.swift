import CompanionProtocol
import Domain
import Foundation

public enum CompanionHistoryMapping {
    public static let frameBudgetBytes = CompanionLimits.maxOutboundFrameBytes - 32 * 1024
    public static let maxScreenTextLength = 4000

    public static func item(_ header: SessionHeader) -> HistoryItem {
        HistoryItem(
            sessionId: CompanionWireMapping.sessionId(header.id),
            kind: header.kind.rawValue,
            title: header.title,
            startedAt: CompanionWireMapping.milliseconds(header.startedAt),
            endedAt: header.endedAt.map(CompanionWireMapping.milliseconds),
            status: status(header.status),
            pinned: header.pinned,
            qaCount: header.questionAnswerCount,
            starCount: header.starCount
        )
    }

    public static func item(_ result: SessionSearchResult) -> HistoryItem {
        HistoryItem(
            sessionId: CompanionWireMapping.sessionId(result.sessionID),
            kind: result.kind.rawValue,
            title: result.title,
            startedAt: CompanionWireMapping.milliseconds(result.startedAt),
            hits: result.hits.map { hit in
                HistoryHit(source: hit.source.rawValue, itemId: hit.itemID, snippet: hit.snippet, at: hit.occurredAt.map(CompanionWireMapping.milliseconds))
            }
        )
    }

    public static func session(_ history: SessionHistoryDetail) -> ServerEvent.HistorySession {
        let session = history.session
        let detail = history.detail
        return ServerEvent.HistorySession(
            sessionId: CompanionWireMapping.sessionId(session.id),
            kind: session.kind.rawValue,
            title: session.title,
            startedAt: CompanionWireMapping.milliseconds(session.startedAt),
            endedAt: session.endedAt.map(CompanionWireMapping.milliseconds),
            status: status(session.status),
            summary: history.summary?.renderedMarkdown,
            qa: history.questions.map { question in
                HistoryQuestion(
                    qaId: question.pair.id.uuidString,
                    askedAt: CompanionWireMapping.milliseconds(question.pair.askedAt),
                    question: question.pair.questionText,
                    answer: question.pair.answerText,
                    status: status(question.pair.status),
                    starred: question.starred,
                    expansions: question.expansions.map(expansion)
                )
            },
            expansions: history.unattachedExpansions.map(expansion),
            transcript: detail.utterances.map { utterance in
                HistoryLine(
                    lineId: utterance.id,
                    speaker: WireSpeaker(rawValue: utterance.speaker.rawValue) ?? .them,
                    text: utterance.text,
                    translation: utterance.translationText,
                    at: utterance.capturedAt.map(CompanionWireMapping.milliseconds)
                )
            },
            moments: detail.bookmarks.map { bookmark in
                HistoryMoment(
                    bookmarkId: bookmark.id,
                    kind: bookmark.kind == .star ? .star : .moment,
                    markedAt: CompanionWireMapping.milliseconds(bookmark.markedAt),
                    qaId: bookmark.questionAnswerID?.uuidString,
                    note: bookmark.note
                )
            },
            screens: detail.screenContexts.map { screen in
                HistoryScreen(
                    screenId: screen.id,
                    capturedAt: CompanionWireMapping.milliseconds(screen.capturedAt),
                    application: screen.application,
                    text: String(screen.text.prefix(maxScreenTextLength))
                )
            },
            truncated: false
        )
    }

    public static func fitted(_ session: ServerEvent.HistorySession, budget: Int = frameBudgetBytes) -> ServerEvent.HistorySession {
        guard size(session) > budget else { return session }
        let lines = session.transcript
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high + 1) / 2
            if size(session.withTranscript(Array(lines.prefix(middle)), truncated: true)) <= budget {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return session.withTranscript(Array(lines.prefix(low)), truncated: true)
    }

    static func size(_ session: ServerEvent.HistorySession) -> Int {
        (try? JSONEncoder().encode(session).count) ?? Int.max
    }

    static func expansion(_ expansion: SessionExpansion) -> HistoryExpansion {
        HistoryExpansion(
            expansionId: expansion.id,
            requestedAt: CompanionWireMapping.milliseconds(expansion.requestedAt),
            model: expansion.modelID,
            status: expansion.status,
            text: expansion.text
        )
    }

    static func status(_ status: MeetingStatus) -> String {
        switch status {
        case .recording: "recording"
        case .completed: "completed"
        case .interrupted: "interrupted"
        case .failed: "failed"
        }
    }

    static func status(_ status: AnswerRecordStatus) -> String {
        switch status {
        case .answerStreaming: "streaming"
        case .completed: "completed"
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
    }
}
