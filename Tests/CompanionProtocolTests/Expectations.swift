import CompanionProtocol
import Foundation

enum Expectations {
    static func envelope(_ seq: Int, sid: String? = nil, _ event: ServerEvent) -> ServerEnvelope {
        ServerEnvelope(seq: seq, ts: 1_762_700_000_000 + Int64(seq), sid: sid, event: event)
    }

    static let server: [String: ServerEnvelope] = [
        "hello.ok": envelope(1, .helloOK(.init(deviceId: "dev_a1", serverVersion: "0.2.0", replayed: false))),
        "pair.ok": envelope(2, .pairOK(.init(deviceId: "dev_a1", deviceToken: "tok_base64url_value"))),
        "state.snapshot": envelope(3, sid: "ses_1", .stateSnapshot(StateSnapshot(
            mode: ModeInfo(mode: .answers, phase: .active, startedAt: 1_762_699_990_000),
            answer: AnswerState(
                answerId: "resp_1",
                trigger: .manual,
                status: .streaming,
                text: "1. Начну с контекста задачи\n2. Затем метрики",
                points: [
                    AnswerPoint(pointId: "resp_1.0", index: 0, start: 0, end: 27, open: false),
                    AnswerPoint(pointId: "resp_1.1", index: 1, start: 28, end: 44, open: true),
                ]
            ),
            transcript: [TranscriptLine(itemId: "item_1", speaker: .them, text: "Расскажите про проект", isFinal: true, language: "ru")],
            levels: [LevelInfo(source: .system, rmsDBFS: -32.5, peakDBFS: -12.25)],
            notices: [NoticeInfo(code: "output_route_speakers", severity: .warning, args: ["route": "speakers"])],
            session: SessionInfo(sessionId: "ses_1", startedAt: 1_762_699_000_000, title: "Interview"),
            overlayEnabled: false,
            capabilities: ["answer_now", "reset_context", "set_mode"]
        ))),
        "mode.changed": envelope(4, .modeChanged(ModeInfo(mode: .recording, phase: .starting))),
        "notice": envelope(5, .notice(NoticeInfo(code: "fell_back_to_whole_system", severity: .info, message: "Chrome is not running", args: ["bundleId": "com.google.Chrome"]))),
        "level": envelope(6, .level(LevelInfo(source: .me, rmsDBFS: -48, peakDBFS: -30.5))),
        "transcript.delta": envelope(7, .transcriptDelta(TranscriptLine(itemId: "item_2", speaker: .them, text: "What was the hardest", isFinal: false))),
        "answer.started": envelope(8, .answerStarted(.init(answerId: "resp_2", trigger: .auto, startedAt: 1_762_700_000_008))),
        "answer.delta": envelope(9, .answerDelta(.init(answerId: "resp_2", offset: 0, text: "1. Ключевой риск", points: [AnswerPoint(pointId: "resp_2.0", index: 0, start: 0, end: 16, open: true)]))),
        "answer.replace": envelope(10, .answerReplace(.init(answerId: "resp_2", text: "1. Главный риск"))),
        "answer.done": envelope(11, .answerDone(.init(answerId: "resp_2", status: .completed, length: 15))),
        "session.started": envelope(12, sid: "ses_2", .sessionStarted(SessionInfo(sessionId: "ses_2", startedAt: 1_762_700_000_012))),
        "session.stopped": envelope(13, sid: "ses_2", .sessionStopped(.init(sessionId: "ses_2", endedAt: 1_762_700_000_013))),
        "deep.started": envelope(14, .deepStarted(.init(requestId: "deep_1", pointId: "resp_2.0", model: .sonnet, format: .steps, language: .both))),
        "deep.delta": envelope(15, .deepDelta(.init(requestId: "deep_1", offset: 0, text: "Step one"))),
        "deep.done": envelope(16, .deepDone(.init(requestId: "deep_1", status: .failed, errorCode: "rate_limited"))),
        "screen.captured": envelope(17, .screenCaptured(.init(captureId: "cap_1", capturedAt: 1_762_700_000_017, charCount: 512, preview: "func solve("))),
        "ack": envelope(18, .ack(.init(cmdId: "c-01", ok: false, code: "not_available", message: "expand is not available yet"))),
        "error": envelope(19, .error(.init(code: "unauthorized", fatal: true))),
        "pong": envelope(20, .pong(.init(nonce: "n1"))),
    ]

    static let client: [String: ClientCommand] = [
        "hello": ClientCommand(cmdId: "c-hello", action: .hello(.init(token: "tok_base64url_value", lastSeq: 42, clientVersion: 1))),
        "pair": ClientCommand(cmdId: "c-pair", action: .pair(.init(code: "483920", deviceName: "MacBook Air M1"))),
        "ping": ClientCommand(cmdId: "c-ping", action: .ping(.init(nonce: "n1"))),
        "answer_now": ClientCommand(cmdId: "c-answer", action: .answerNow),
        "set_mode": ClientCommand(cmdId: "c-mode", action: .setMode(.init(mode: .passive))),
        "reset_context": ClientCommand(cmdId: "c-reset", action: .resetContext),
        "expand": ClientCommand(cmdId: "c-expand", action: .expand(.init(pointId: "resp_2.0", freeText: "Покажи на примере", format: .code, model: .opus, language: .ru))),
        "capture_screen": ClientCommand(cmdId: "c-screen", action: .captureScreen),
        "session.start": ClientCommand(cmdId: "c-ses-start", action: .sessionStart(.init(title: "Interview"))),
        "session.stop": ClientCommand(cmdId: "c-ses-stop", action: .sessionStop),
    ]
}

enum Fixtures {
    static func url(_ group: String, _ name: String) throws -> URL {
        guard let root = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root.appendingPathComponent(group).appendingPathComponent("\(name).json")
    }

    static func data(_ group: String, _ name: String) throws -> Data {
        try Data(contentsOf: url(group, name))
    }

    static func names(_ group: String) throws -> Set<String> {
        guard let root = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(group).path)
        return Set(files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
    }

    static func jsonObject(_ data: Data) throws -> NSObject {
        try JSONSerialization.jsonObject(with: data) as! NSObject
    }
}
