@testable import CompanionProtocol
import Foundation
import Testing

@Suite struct DeltaDifferTests {
    @Test func growingTextProducesAppendWithUTF16Offset() {
        var differ = DeltaDiffer()
        #expect(differ.update("При") == .append(offset: 0, text: "При"))
        #expect(differ.update("Привет") == .append(offset: 3, text: "вет"))
        #expect(differ.update("Привет") == TextChange.none)
    }

    @Test func emojiOffsetsCountUTF16Units() {
        var differ = DeltaDiffer()
        _ = differ.update("😀")
        #expect(differ.update("😀 ok") == .append(offset: 2, text: " ok"))
    }

    @Test func combiningMarkOnGraphemeBoundaryStillAppends() {
        var differ = DeltaDiffer()
        _ = differ.update("Cafe")
        #expect(differ.update("Cafe\u{301}") == .append(offset: 4, text: "\u{301}"))
    }

    @Test func zwjSequenceGrowingAppends() {
        var differ = DeltaDiffer()
        _ = differ.update("👨")
        let change = differ.update("👨‍👩‍👧")
        guard case .append(let offset, let text) = change else { Issue.record("expected append"); return }
        #expect(offset == 2)
        #expect("👨" + text == "👨‍👩‍👧")
    }

    @Test func changedPrefixProducesReplace() {
        var differ = DeltaDiffer()
        _ = differ.update("Ответ: да")
        #expect(differ.update("Ответ: нет") == .replace(text: "Ответ: нет"))
        #expect(differ.update("Ответ") == .replace(text: "Ответ"))
    }

    @Test func appliedChangesReconstructTheText() {
        var differ = DeltaDiffer()
        var client = ""
        for step in ["1", "1. Зап", "1. Запуск 🚀", "1. Запуск 🚀\n2. Мет", "1. Старт", "1. Старт и всё"] {
            switch differ.update(step) {
            case .none: break
            case .append(let offset, let text):
                #expect(client.utf16.count == offset)
                client += text
            case .replace(let text): client = text
            }
            #expect(client == step)
        }
    }
}

@Suite struct PointSegmenterTests {
    private func slices(_ text: String, _ points: [AnswerPoint]) -> [String] {
        let utf16 = Array(text.utf16)
        return points.map { String(decoding: utf16[$0.start..<$0.end], as: UTF16.self) }
    }

    @Test func dashAndNumberedItemsSplit() {
        let text = "- Первый\n- Второй\n1. Третий\n2) Четвёртый"
        let points = PointSegmenter.segment(text, answerId: "r", isFinal: true)
        #expect(slices(text, points) == ["- Первый", "- Второй", "1. Третий", "2) Четвёртый"])
        #expect(points.map(\.pointId) == ["r.0", "r.1", "r.2", "r.3"])
        #expect(points.allSatisfy { !$0.open })
    }

    @Test func nestedItemsAndContinuationsBelongToParent() {
        let text = "1. Архитектура\n   - сервисы\n   - очередь\n2. Метрики\n  продолжение"
        let points = PointSegmenter.segment(text, answerId: "r", isFinal: false)
        #expect(slices(text, points) == ["1. Архитектура\n   - сервисы\n   - очередь", "2. Метрики\n  продолжение"])
        #expect(points.map(\.open) == [false, true])
    }

    @Test func paragraphsAndHeadingsAreBlocks() {
        let text = "Короткий ответ.\nЕщё строка.\n\n# План\n- шаг"
        let points = PointSegmenter.segment(text, answerId: "a", isFinal: true)
        #expect(slices(text, points) == ["Короткий ответ.\nЕщё строка.", "# План", "- шаг"])
    }

    @Test func paragraphAfterListAndBlankLineIsNewBlock() {
        let text = "- один\n\n  вложенный абзац\n\nИтог"
        let points = PointSegmenter.segment(text, answerId: "a", isFinal: true)
        #expect(slices(text, points) == ["- один\n\n  вложенный абзац", "Итог"])
    }

    @Test func codeFenceIsNotSplit() {
        let text = "1. Код:\n```\n- not an item\n\n1. nope\n```\n2. Дальше"
        let points = PointSegmenter.segment(text, answerId: "a", isFinal: true)
        #expect(slices(text, points) == ["1. Код:\n```\n- not an item\n\n1. nope\n```", "2. Дальше"])
    }

    @Test func dashWithoutSpaceAndLongNumbersAreNotItems() {
        #expect(!PointSegmenter.isListItem("-1 градус"))
        #expect(!PointSegmenter.isListItem("2024. год"))
        #expect(PointSegmenter.isListItem("10. десятый"))
        #expect(PointSegmenter.isListItem("* звезда"))
    }

    @Test func streamedPointKeepsItsIdAndIndexesOnlyGrow() {
        let full = "1. Первый пункт\n2. Второй пункт с 😀\n3. Третий"
        var known: [Int: String] = [:]
        var lastCount = 0
        var prefix = ""
        for character in full {
            prefix.append(character)
            let points = PointSegmenter.segment(prefix, answerId: "r", isFinal: false)
            #expect(points.count >= lastCount)
            lastCount = points.count
            for point in points {
                if let id = known[point.index] { #expect(id == point.pointId) }
                known[point.index] = point.pointId
            }
            #expect(points.last?.open ?? true)
        }
        #expect(lastCount == 3)
    }

    @Test func crlfLineEndsAreHandled() {
        let text = "- a\r\n- b"
        let points = PointSegmenter.segment(text, answerId: "r", isFinal: true)
        #expect(slices(text, points) == ["- a", "- b"])
    }

    @Test func emptyTextHasNoPoints() {
        #expect(PointSegmenter.segment("", answerId: "r", isFinal: false).isEmpty)
    }
}

@Suite struct WireTextSanitizerTests {
    @Test func completeMarkerIsRemoved() {
        #expect(WireTextSanitizer.sanitize("⟦WAIT_FOR_QUESTION⟧", isFinal: true) == "")
        #expect(WireTextSanitizer.sanitize("Ответ ⟦WAIT_FOR_QUESTION⟧", isFinal: false) == "Ответ ")
    }

    @Test func partialMarkerIsHeldBackWhileStreaming() {
        #expect(WireTextSanitizer.sanitize("Ответ ⟦WAIT_FO", isFinal: false) == "Ответ ")
        #expect(WireTextSanitizer.sanitize("⟦", isFinal: false) == "")
    }

    @Test func bracketThatIsNotAMarkerIsKept() {
        #expect(WireTextSanitizer.sanitize("⟦x⟧ и ⟦⟧", isFinal: false) == "⟦x⟧ и ⟦⟧")
        #expect(WireTextSanitizer.sanitize("хвост ⟦ABC", isFinal: true) == "хвост ⟦ABC")
    }

    @Test func markerNeverReachesTheWireThroughProjector() throws {
        var projector = AnswerStreamProjector(answerId: "r", trigger: .auto)
        var wire: [ServerEvent] = []
        for step in ["⟦", "⟦WAIT", "⟦WAIT_FOR_QUESTION", "⟦WAIT_FOR_QUESTION⟧"] {
            if let event = projector.update(accumulated: step) { wire.append(event) }
        }
        wire += projector.finish(.cancelled, finalText: "⟦WAIT_FOR_QUESTION⟧")
        let encoded = try wire.map { try CompanionCodec.encode(ServerEnvelope(seq: 1, ts: 1, event: $0)) }
        #expect(encoded.allSatisfy { !String(decoding: $0, as: UTF8.self).contains("WAIT_FOR_QUESTION") })
        #expect(wire == [.answerDone(.init(answerId: "r", status: .cancelled, length: 0))])
    }
}

@Suite struct AnswerStreamProjectorTests {
    @Test func streamingProducesDeltasThenDoneWithClosedPoints() {
        var projector = AnswerStreamProjector(answerId: "resp", trigger: .manual)
        let first = projector.update(accumulated: "1. Риск")
        #expect(first == .answerDelta(.init(answerId: "resp", offset: 0, text: "1. Риск", points: [AnswerPoint(pointId: "resp.0", index: 0, start: 0, end: 7, open: true)])))
        let second = projector.update(accumulated: "1. Риск\n2. План")
        #expect(second == .answerDelta(.init(answerId: "resp", offset: 7, text: "\n2. План", points: [
            AnswerPoint(pointId: "resp.0", index: 0, start: 0, end: 7, open: false),
            AnswerPoint(pointId: "resp.1", index: 1, start: 8, end: 15, open: true),
        ])))
        #expect(projector.update(accumulated: "1. Риск\n2. План") == nil)
        let done = projector.finish(.completed, finalText: "1. Риск\n2. План")
        #expect(done == [.answerDone(.init(answerId: "resp", status: .completed, length: 15, points: [AnswerPoint(pointId: "resp.1", index: 1, start: 8, end: 15, open: false)]))])
        #expect(projector.state.status == .completed)
        #expect(projector.state.points.allSatisfy { !$0.open })
        #expect(projector.update(accumulated: "more") == nil)
        #expect(projector.finish(.completed).isEmpty)
    }

    @Test func rewrittenPrefixProducesReplaceWithAllPoints() {
        var projector = AnswerStreamProjector(answerId: "r", trigger: .auto)
        _ = projector.update(accumulated: "- a\n- b")
        let event = projector.update(accumulated: "- x")
        #expect(event == .answerReplace(.init(answerId: "r", text: "- x", points: [AnswerPoint(pointId: "r.0", index: 0, start: 0, end: 3, open: true)])))
    }

    @Test func finalTextDifferentFromStreamIsReconciledBeforeDone() {
        var projector = AnswerStreamProjector(answerId: "r", trigger: .auto)
        _ = projector.update(accumulated: "Да")
        let events = projector.finish(.completed, finalText: "Да, конечно")
        #expect(events.count == 2)
        #expect(events.first == .answerDelta(.init(answerId: "r", offset: 2, text: ", конечно", points: [AnswerPoint(pointId: "r.0", index: 0, start: 0, end: 11, open: true)])))
        #expect(events.last == .answerDone(.init(answerId: "r", status: .completed, length: 11, points: [AnswerPoint(pointId: "r.0", index: 0, start: 0, end: 11, open: false)])))
        #expect(projector.state.text == "Да, конечно")
    }
}

@Suite struct ReplayBufferTests {
    private func envelope(_ seq: Int, _ event: ServerEvent = .notice(NoticeInfo(code: "n", severity: .info))) -> ServerEnvelope {
        ServerEnvelope(seq: seq, ts: Int64(seq), event: event)
    }

    @Test func returnsEventsAfterLastSeq() throws {
        var buffer = ReplayBuffer(capacity: 10)
        for seq in 1...5 { buffer.append(envelope(seq)) }
        #expect(try #require(buffer.events(after: 3)).map(\.seq) == [4, 5])
        #expect(buffer.events(after: 5) == [])
        #expect(try #require(buffer.events(after: 0)).map(\.seq) == [1, 2, 3, 4, 5])
    }

    @Test func overflowEvictsOldestAndAsksForSnapshot() throws {
        var buffer = ReplayBuffer(capacity: 3)
        for seq in 1...7 { buffer.append(envelope(seq)) }
        #expect(buffer.count == 3)
        #expect(buffer.events(after: 3) == nil)
        #expect(try #require(buffer.events(after: 4)).map(\.seq) == [5, 6, 7])
        #expect(try #require(buffer.events(after: 6)).map(\.seq) == [7])
    }

    @Test func lastSeqFromTheFutureAsksForSnapshot() {
        var buffer = ReplayBuffer(capacity: 3)
        buffer.append(envelope(1))
        #expect(buffer.events(after: 2) == nil)
        #expect(buffer.events(after: -1) == nil)
    }

    @Test func transientEventsTakeSeqButAreNotStored() throws {
        var buffer = ReplayBuffer(capacity: 2)
        buffer.append(envelope(1))
        for seq in 2...50 { buffer.append(envelope(seq, .level(LevelInfo(source: .system, rmsDBFS: -30, peakDBFS: -20)))) }
        buffer.append(envelope(51))
        #expect(buffer.latestSeq == 51)
        #expect(buffer.count == 2)
        #expect(try #require(buffer.events(after: 10)).map(\.seq) == [51])
        #expect(try #require(buffer.events(after: 0)).map(\.seq) == [1, 51])
    }

    @Test func nonIncreasingSeqIsIgnored() throws {
        var buffer = ReplayBuffer(capacity: 5)
        buffer.append(envelope(2))
        buffer.append(envelope(2))
        buffer.append(envelope(1))
        #expect(buffer.count == 1)
        #expect(try #require(buffer.events(after: 0)).map(\.seq) == [2])
    }

    @Test func removeAllForcesSnapshotForOlderClients() throws {
        var buffer = ReplayBuffer(capacity: 5)
        for seq in 1...3 { buffer.append(envelope(seq)) }
        buffer.removeAll()
        #expect(buffer.events(after: 1) == nil)
        #expect(buffer.events(after: 3) == [])
        buffer.append(envelope(4))
        #expect(try #require(buffer.events(after: 3)).map(\.seq) == [4])
    }
}
