import Domain
import Foundation
import Testing
@testable import Persistence

@Suite struct SQLiteSessionRepositoryTests {
    private let base = Date(timeIntervalSince1970: 1_793_000_000)

    private func at(_ seconds: Int) -> Date {
        base.addingTimeInterval(TimeInterval(seconds))
    }

    private func makeRepository() -> (SQLiteSessionRepository, SQLiteDatabase) {
        let database = SQLiteDatabase(path: ":memory:")
        return (SQLiteSessionRepository(database: database), database)
    }

    private func insertAnswer(_ database: SQLiteDatabase, session: SessionID, id: UUID = UUID(), askedAt: Date, question: String) async throws {
        let stamp = ISO8601DateFormatter().string(from: askedAt)
        try await database.run(
            "INSERT INTO qa_entries (id, asked_at, question_status, trigger_kind, answer_text, answer_status, model_id, created_at, updated_at, question_text, session_id) VALUES (?, ?, 'completed', 'manual', 'ответ', 'completed', 'gpt-realtime-2.1', ?, ?, ?, ?)",
            [.text(id.uuidString), .text(stamp), .text(stamp), .text(stamp), .text(question), .text(session.rawValue.uuidString)]
        )
    }

    @Test func createStartsActiveSessionWithOneOpenSpan() async throws {
        let (repository, _) = makeRepository()
        let created = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        let stored = try #require(try await repository.session(id: created.id))
        #expect(stored == created)
        #expect(stored.status == .recording)
        #expect(stored.kind == .assistant)
        #expect(stored.spans.count == 1)
        #expect(stored.openSpan?.mode == .answers)
        #expect(stored.lastActivityAt == at(0))
        #expect(try await repository.session(id: SessionID()) == nil)
    }

    @Test func knowledgeDigestRoundTripsPerSession() async throws {
        let (repository, _) = makeRepository()
        let first = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        let second = try await repository.create(kind: .assistant, mode: .answers, at: at(1))
        #expect(try await repository.knowledgeDigest(sessionID: first.id) == nil)
        try await repository.setKnowledgeDigest(sessionID: first.id, digest: "abc")
        try await repository.setKnowledgeDigest(sessionID: first.id, digest: "def")
        #expect(try await repository.knowledgeDigest(sessionID: first.id) == "def")
        #expect(try await repository.knowledgeDigest(sessionID: second.id) == nil)
        #expect(try await repository.knowledgeDigest(sessionID: SessionID()) == nil)
    }

    @Test func resumeAppendsSpanAndClosesPreviousOne() async throws {
        let (repository, _) = makeRepository()
        let created = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        let same = try await repository.resume(sessionID: created.id, mode: .answers, at: at(5))
        #expect(same.id == created.spans[0].id)

        let recording = try await repository.resume(sessionID: created.id, mode: .recording, at: at(10))
        let stored = try #require(try await repository.session(id: created.id))
        #expect(stored.spans.map(\.mode) == [.answers, .recording])
        #expect(stored.spans[0].endedAt == at(10))
        #expect(stored.spans[0].endReason == .modeChanged)
        #expect(stored.openSpan?.id == recording.id)
        #expect(stored.lastActivityAt == at(10))
    }

    @Test func closeSpanRecordsReasonOnce() async throws {
        let (repository, _) = makeRepository()
        let created = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        try await repository.closeSpan(id: created.spans[0].id, at: at(30), reason: .modeChanged)
        try await repository.closeSpan(id: created.spans[0].id, at: at(60), reason: .stopped)
        let stored = try #require(try await repository.session(id: created.id))
        #expect(stored.spans[0].endedAt == at(30))
        #expect(stored.spans[0].endReason == .modeChanged)
        #expect(stored.openSpan == nil)
        #expect(stored.status == .recording)
        #expect(stored.lastActivityAt == at(30))
    }

    @Test func finishCompletesAndResumeReopens() async throws {
        let (repository, _) = makeRepository()
        let created = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        try await repository.finish(sessionID: created.id, at: at(100))
        var stored = try #require(try await repository.session(id: created.id))
        #expect(stored.status == .completed)
        #expect(stored.endedAt == at(100))
        #expect(stored.spans[0].endReason == .stopped)

        _ = try await repository.resume(sessionID: created.id, mode: .answers, at: at(200))
        stored = try #require(try await repository.session(id: created.id))
        #expect(stored.status == .recording)
        #expect(stored.endedAt == nil)
        #expect(stored.spans.count == 2)
        #expect(stored.openSpan?.startedAt == at(200))
        await #expect(throws: (any Error).self) { _ = try await repository.resume(sessionID: SessionID(), mode: .answers, at: at(1)) }
    }

    @Test func headersPaginateNewestFirstWithCounts() async throws {
        let (repository, database) = makeRepository()
        var ids: [SessionID] = []
        for index in 0..<5 {
            ids.append(try await repository.create(kind: .assistant, mode: .answers, at: at(index * 60)).id)
        }
        let tie = try await repository.create(kind: .recording, mode: .recording, at: at(4 * 60))
        try await insertAnswer(database, session: ids[4], askedAt: at(241), question: "первый")
        try await insertAnswer(database, session: ids[4], askedAt: at(242), question: "второй")
        try await repository.addBookmark(SessionBookmark(sessionID: ids[4], kind: .star, markedAt: at(243)))
        try await repository.addBookmark(SessionBookmark(sessionID: ids[4], kind: .moment, markedAt: at(244)))

        var seen: [SessionID] = []
        var cursor: SessionCursor?
        var pages = 0
        repeat {
            let page = try await repository.headers(limit: 2, after: cursor)
            seen += page.headers.map(\.id)
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 10
        #expect(pages == 3)
        #expect(seen.count == 6)
        #expect(Set(seen) == Set(ids + [tie.id]))
        #expect(Set(seen.prefix(2)) == [ids[4], tie.id])
        #expect(Array(seen.suffix(4)) == [ids[3], ids[2], ids[1], ids[0]])

        let first = try await repository.headers(limit: 10, after: nil)
        let header = try #require(first.headers.first { $0.id == ids[4] })
        #expect(header.questionAnswerCount == 2)
        #expect(header.starCount == 1)
        #expect(header.lastActivityAt == at(244))
        #expect(first.headers.first { $0.id == tie.id }?.kind == .recording)
        #expect(first.nextCursor == nil)
    }

    @Test func headersDoNotLoadSegments() async throws {
        let (repository, database) = makeRepository()
        let created = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        try await database.run("DROP TABLE utterances")
        let page = try await repository.headers(limit: 10, after: nil)
        #expect(page.headers.map(\.id) == [created.id])
    }

    @Test func detailReturnsEverythingInOrder() async throws {
        let (repository, database) = makeRepository()
        let created = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        let other = try await repository.create(kind: .assistant, mode: .answers, at: at(1))
        let key = created.id.rawValue.uuidString
        try await database.run("INSERT INTO utterances (id, meeting_id, source, started_ms, ended_ms, text, created_at, speaker, origin, captured_at, translation_text, translation_lang) VALUES ('u2', ?, 'remote', 0, 1, 'Second', ?, 'them', 'realtime_input', ?, 'Второй', 'ru')", [.text(key), .text("2026-11-01T00:00:00Z"), .text(ISO8601DateFormatter().string(from: at(20)))])
        try await database.run("INSERT INTO utterances (id, meeting_id, source, started_ms, ended_ms, text, created_at, speaker, origin, captured_at) VALUES ('u1', ?, 'local', 0, 1, 'Я начну', ?, 'me', 'me_channel', ?)", [.text(key), .text("2026-11-01T00:00:00Z"), .text(ISO8601DateFormatter().string(from: at(10)))])
        let answerID = UUID()
        try await insertAnswer(database, session: created.id, id: answerID, askedAt: at(25), question: "Как шардировать?")
        try await insertAnswer(database, session: other.id, askedAt: at(26), question: "чужой")
        try await database.run("INSERT INTO deep_expansions (id, session_id, qa_entry_id, requested_at, model_id, status, text, created_at, updated_at) VALUES ('d1', ?, ?, ?, 'claude-sonnet-5-5', 'completed', 'Подробно', 'x', 'x')", [.text(key), .text(answerID.uuidString), .text(ISO8601DateFormatter().string(from: at(30)))])
        try await database.run("INSERT INTO screen_contexts (id, session_id, captured_at, application, window_title, text, created_at) VALUES ('s1', ?, ?, 'Xcode', 'Order.swift', 'struct Order', 'x')", [.text(key), .text(ISO8601DateFormatter().string(from: at(15)))])
        let star = SessionBookmark(sessionID: created.id, kind: .star, questionAnswerID: answerID, markedAt: at(31), note: "важно")
        try await repository.addBookmark(star)

        let detail = try #require(try await repository.detail(sessionID: created.id))
        #expect(detail.session.id == created.id)
        #expect(detail.utterances.map(\.id) == ["u1", "u2"])
        #expect(detail.utterances[0].speaker == .me)
        #expect(detail.utterances[0].origin == .meChannel)
        #expect(detail.utterances[1].translationText == "Второй")
        #expect(detail.questionAnswers.map(\.id) == [answerID])
        #expect(detail.bookmarks == [star])
        #expect(detail.expansions.map(\.questionAnswerID) == [answerID])
        #expect(detail.screenContexts.map(\.application) == ["Xcode"])
        #expect(try await repository.detail(sessionID: SessionID()) == nil)

        try await repository.removeBookmark(id: star.id)
        #expect(try await repository.detail(sessionID: created.id)?.bookmarks.isEmpty == true)
    }

    @Test func titleAndPinRoundTrip() async throws {
        let (repository, _) = makeRepository()
        let created = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        try await repository.setTitle(sessionID: created.id, title: "Интервью: шардинг", source: .user)
        try await repository.setPinned(sessionID: created.id, pinned: true)
        let stored = try #require(try await repository.session(id: created.id))
        #expect(stored.title == "Интервью: шардинг")
        #expect(stored.titleSource == .user)
        #expect(stored.pinned)
        try await repository.setPinned(sessionID: created.id, pinned: false)
        #expect(try await repository.session(id: created.id)?.pinned == false)
    }

    @Test func purgeSkipsPinnedActiveOpenAndRecent() async throws {
        let (repository, database) = makeRepository()
        let old = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        try await repository.finish(sessionID: old.id, at: at(10))
        try await insertAnswer(database, session: old.id, askedAt: at(5), question: "старый")
        let pinned = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        try await repository.finish(sessionID: pinned.id, at: at(10))
        try await repository.setPinned(sessionID: pinned.id, pinned: true)
        let active = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        try await repository.finish(sessionID: active.id, at: at(10))
        let open = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        let recent = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        try await repository.finish(sessionID: recent.id, at: at(5_000))

        let purged = try await repository.purge(olderThan: at(1_000), excluding: active.id)
        #expect(purged == [old.id])
        #expect(try await repository.session(id: old.id) == nil)
        #expect(try await database.query("SELECT COUNT(*) FROM qa_entries", map: { $0.int(0) ?? 0 }) == [0])
        for kept in [pinned.id, active.id, open.id, recent.id] {
            #expect(try await repository.session(id: kept) != nil)
        }
        #expect(try await repository.purge(olderThan: at(1_000), excluding: nil) == [active.id])
    }

    @Test func utterancesAreStoredWithSpeakerOriginWallClockAndOffset() async throws {
        let (repository, database) = makeRepository()
        let session = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        try await repository.appendUtterance(SessionUtterance(id: "utt_1", speaker: .them, origin: .realtimeInput, text: "Почему Кафка?", capturedAt: at(12), language: "ru"), sessionID: session.id)
        try await repository.appendUtterance(SessionUtterance(id: "utt_2", speaker: .me, origin: .meChannel, text: "Из-за ретеншна", capturedAt: at(15)), sessionID: session.id)
        let detail = try #require(try await repository.detail(sessionID: session.id))
        #expect(detail.utterances.map(\.id) == ["utt_1", "utt_2"])
        #expect(detail.utterances.map(\.speaker) == [.them, .me])
        #expect(detail.utterances.map(\.origin) == [.realtimeInput, .meChannel])
        #expect(detail.utterances.map(\.capturedAt) == [at(12), at(15)])
        #expect(try await repository.session(id: session.id)?.lastActivityAt == at(15))
        let meetings = SQLiteMeetingRepository(database: database)
        let segments = try await meetings.fetch(meetingID: session.id).segments
        #expect(segments.map(\.startMs) == [12_000, 15_000])
        #expect(segments.map(\.source) == [.remote, .local])
    }

    @Test func emptySessionIsDeletedButContentOrRecordingKeepsIt() async throws {
        let (repository, database) = makeRepository()
        let empty = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        #expect(try await repository.deleteIfEmpty(sessionID: empty.id))
        #expect(try await repository.session(id: empty.id) == nil)

        let spoken = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        try await repository.appendUtterance(SessionUtterance(id: "utt_x", speaker: .them, origin: .realtimeInput, text: "Вопрос", capturedAt: at(1)), sessionID: spoken.id)
        #expect(try await repository.deleteIfEmpty(sessionID: spoken.id) == false)

        let answered = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        try await insertAnswer(database, session: answered.id, askedAt: at(2), question: "Что такое WAL?")
        #expect(try await repository.deleteIfEmpty(sessionID: answered.id) == false)

        let recorded = try await repository.create(kind: .assistant, mode: .recording, at: at(0))
        #expect(try await repository.deleteIfEmpty(sessionID: recorded.id) == false)

        let pinned = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        try await repository.setPinned(sessionID: pinned.id, pinned: true)
        #expect(try await repository.deleteIfEmpty(sessionID: pinned.id) == false)
    }

    @Test func savedAnswerKeepsSessionIDAndBumpsActivity() async throws {
        let (repository, database) = makeRepository()
        let session = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        let answers = SQLiteQuestionAnswerRepository(database: database)
        var pair = QuestionAnswerPair(askedAt: at(30), sourceAppBundleID: nil, contextWindowStartedAt: at(20), contextWindowDurationMs: 10_000, triggerKind: .manual, answerText: "", answerModelID: "m", responseID: "r1", status: .answerStreaming, sessionID: session.id)
        try await answers.save(pair)
        pair.answerText = "Ответ"
        pair.status = .completed
        pair.sessionID = nil
        try await answers.save(pair)
        let detail = try #require(try await repository.detail(sessionID: session.id))
        #expect(detail.questionAnswers.map(\.answerText) == ["Ответ"])
        #expect(detail.questionAnswers.first?.sessionID == session.id)
        #expect(try await repository.latestCompletedAnswerID(sessionID: session.id) == pair.id)
        let activity = try #require(try await repository.session(id: session.id)?.lastActivityAt)
        #expect(activity > at(0))
    }

    @Test func recordingSegmentInSessionUsesWallClockOffset() async throws {
        let (repository, database) = makeRepository()
        let session = try await repository.create(kind: .assistant, mode: .answers, at: at(0))
        let meetings = SQLiteMeetingRepository(database: database)
        try await meetings.appendSegment(TranscribedSegment(text: "в записи", startMs: 500, endMs: 1_500, source: .remote), meetingID: session.id, capturedAt: at(60))
        try await repository.appendUtterance(SessionUtterance(id: "utt_a", speaker: .me, origin: .meChannel, text: "раньше", capturedAt: at(10)), sessionID: session.id)
        let detail = try #require(try await repository.detail(sessionID: session.id))
        #expect(detail.utterances.map(\.text) == ["раньше", "в записи"])
        #expect(detail.utterances.last?.origin == .whisperLocal)
        #expect(detail.utterances.last?.capturedAt == at(60))
        let segments = try await meetings.fetch(meetingID: session.id).segments
        #expect(segments.map(\.startMs) == [10_000, 60_000])
        #expect(segments.last?.endMs == 61_000)
    }
}
