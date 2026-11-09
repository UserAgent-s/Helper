import CompanionServer
import Foundation
import JavaScriptCore
import Testing

final class WebModuleContext {
    let context: JSContext
    private(set) var exceptions: [String] = []

    init(modules: [String], prelude: String = "") throws {
        guard let context = JSContext() else { throw WebModuleError.noContext }
        self.context = context
        context.exceptionHandler = { [weak self] _, value in
            self?.exceptions.append(value?.toString() ?? "unknown")
        }
        if !prelude.isEmpty { context.evaluateScript(prelude) }
        for module in modules {
            guard let source = CompanionWebAssets.text(named: module) else { throw WebModuleError.missing(module) }
            context.evaluateScript(Self.classicScript(source), withSourceURL: URL(string: "ua057:///\(module)"))
        }
        guard exceptions.isEmpty else { throw WebModuleError.exception(exceptions.joined(separator: "; ")) }
    }

    static func classicScript(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("import ") }
            .map { $0.hasPrefix("export ") ? String($0.dropFirst("export ".count)) : String($0) }
            .joined(separator: "\n")
    }

    @discardableResult
    func run(_ script: String) throws -> Any? {
        let value = context.evaluateScript("JSON.stringify((function(){ \(script) })())")
        guard exceptions.isEmpty else { throw WebModuleError.exception(exceptions.joined(separator: "; ")) }
        guard let text = value?.toString(), text != "undefined" else { return nil }
        return try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    func set(_ name: String, json: String) {
        context.evaluateScript("var \(name) = \(json);")
    }
}

enum WebModuleError: Error {
    case noContext
    case missing(String)
    case exception(String)
}

enum ServerFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("CompanionProtocolTests/Fixtures/server")

    static func json(_ type: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent("\(type).json"), encoding: .utf8)
    }
}

@Suite struct WebReducerJSCTests {
    private func store() throws -> WebModuleContext {
        let module = try WebModuleContext(modules: ["store.js"])
        try module.run("globalThis.state = initialState(); return null;")
        return module
    }

    private func apply(_ module: WebModuleContext, _ envelopes: [String]) throws {
        for (index, envelope) in envelopes.enumerated() {
            module.set("env\(index)", json: envelope)
            try module.run("globalThis.state = applyEnvelope(globalThis.state, env\(index)); return null;")
        }
    }

    private func state(_ module: WebModuleContext) throws -> [String: Any] {
        try #require(try module.run("return globalThis.state;") as? [String: Any])
    }

    private func envelope(_ seq: Int, _ type: String, _ data: String) -> String {
        #"{"v":1,"seq":\#(seq),"ts":\#(seq),"type":"\#(type)","data":\#(data)}"#
    }

    @Test func storeRunsWithoutBrowserOrSecureContextAPIs() throws {
        let module = try store()
        let globals = try #require(try module.run("return [typeof window, typeof crypto, typeof localStorage, typeof document];") as? [String])
        #expect(globals == ["undefined", "undefined", "undefined", "undefined"])
        #expect(module.exceptions.isEmpty)
    }

    @Test func goldenFixturesReduceInSeqOrder() throws {
        let module = try store()
        let order = ["hello.ok", "state.snapshot", "mode.changed", "notice", "level", "transcript.delta", "answer.started", "answer.delta", "answer.replace", "answer.done"]
        try apply(module, try order.map(ServerFixtures.json))
        let state = try state(module)
        #expect(state["connection"] as? String == "online")
        #expect(state["deviceId"] as? String == "dev_a1")
        #expect(state["lastSeq"] as? Int == 11)
        #expect(state["resyncNeeded"] as? Bool == false)
        let answer = try #require(state["answer"] as? [String: Any])
        #expect(answer["answerId"] as? String == "resp_2")
        #expect(answer["text"] as? String == "1. Главный риск")
        #expect(answer["status"] as? String == "completed")
        let mode = try #require(state["mode"] as? [String: Any])
        #expect(mode["mode"] as? String == "recording")
        let transcript = try #require(state["transcript"] as? [[String: Any]])
        #expect(transcript.map { $0["itemId"] as? String } == ["item_1", "item_2"])
        #expect((state["notices"] as? [Any])?.count == 2)
        let levels = try #require(state["levels"] as? [String: Any])
        #expect(Set(levels.keys) == ["system", "me"])
    }

    @Test func deltasAppendAndDuplicatesAreDroppedBySeqAndOffset() throws {
        let module = try store()
        try apply(module, [
            envelope(1, "answer.started", #"{"answerId":"r1","trigger":"manual","startedAt":1}"#),
            envelope(2, "answer.delta", #"{"answerId":"r1","offset":0,"text":"Пер"}"#),
            envelope(3, "answer.delta", #"{"answerId":"r1","offset":3,"text":"вый"}"#),
            envelope(3, "answer.delta", #"{"answerId":"r1","offset":3,"text":"вый"}"#),
            envelope(4, "answer.delta", #"{"answerId":"r1","offset":3,"text":"вый"}"#),
            envelope(5, "answer.delta", #"{"answerId":"r1","offset":6,"text":" ответ"}"#),
        ])
        var answer = try #require(try state(module)["answer"] as? [String: Any])
        #expect(answer["text"] as? String == "Первый ответ")

        try apply(module, [envelope(6, "answer.delta", #"{"answerId":"r1","offset":7,"text":"шаг"}"#)])
        answer = try #require(try state(module)["answer"] as? [String: Any])
        #expect(answer["text"] as? String == "Первый шаг")
        #expect(try state(module)["resyncNeeded"] as? Bool == false)

        try apply(module, [envelope(7, "answer.delta", #"{"answerId":"r1","offset":40,"text":"x"}"#)])
        #expect(try state(module)["resyncNeeded"] as? Bool == true)
    }

    @Test func offsetsCountUTF16UnitsLikeServer() throws {
        let module = try store()
        try apply(module, [
            envelope(1, "answer.started", #"{"answerId":"r1","trigger":"auto","startedAt":1}"#),
            envelope(2, "answer.delta", #"{"answerId":"r1","offset":0,"text":"ok 👍"}"#),
            envelope(3, "answer.delta", #"{"answerId":"r1","offset":\#("ok 👍".utf16.count),"text":" done"}"#),
            envelope(4, "answer.done", #"{"answerId":"r1","status":"completed","length":\#("ok 👍 done".utf16.count)}"#),
        ])
        let state = try state(module)
        #expect((state["answer"] as? [String: Any])?["text"] as? String == "ok 👍 done")
        #expect(state["resyncNeeded"] as? Bool == false)
    }

    @Test func replaceAndDoneLengthMismatchRequestResync() throws {
        let module = try store()
        try apply(module, [
            envelope(1, "answer.started", #"{"answerId":"r1","trigger":"auto","startedAt":1}"#),
            envelope(2, "answer.delta", #"{"answerId":"r1","offset":0,"text":"abc"}"#),
            envelope(3, "answer.replace", #"{"answerId":"r1","text":"xy","points":[{"pointId":"r1.0","index":0,"start":0,"end":2,"open":true}]}"#),
        ])
        var state = try state(module)
        #expect((state["answer"] as? [String: Any])?["text"] as? String == "xy")
        try apply(module, [envelope(4, "answer.done", #"{"answerId":"r1","status":"completed","length":5}"#)])
        state = try self.state(module)
        #expect(state["resyncNeeded"] as? Bool == true)
        try module.run("globalThis.state = applyLocal(globalThis.state, {type: 'forgetSeq'}); return null;")
        state = try self.state(module)
        #expect(state["lastSeq"] is NSNull)
        #expect(state["resyncNeeded"] as? Bool == false)
    }

    @Test func snapshotAfterStreamMatchesFreshSnapshot() throws {
        let streamed = try store()
        try apply(streamed, try ["state.snapshot", "answer.started", "answer.delta", "answer.replace"].map(ServerFixtures.json))
        let snapshot = envelope(12, "state.snapshot", #"""
        {"mode":{"mode":"answers","phase":"active"},"answer":{"answerId":"resp_2","trigger":"auto","status":"completed","text":"1. Главный риск","points":[{"pointId":"resp_2.0","index":0,"start":0,"end":15,"open":false}]},"transcript":[{"itemId":"item_2","speaker":"them","text":"What was the hardest part","isFinal":true}],"levels":[],"notices":[],"overlayEnabled":true,"capabilities":["answer_now"]}
        """#)
        try apply(streamed, [snapshot])
        let fresh = try store()
        try apply(fresh, [snapshot])
        let keys = ["mode", "answer", "transcript", "levels", "notices", "capabilities", "lastSeq", "session"]
        let left = try state(streamed)
        let right = try state(fresh)
        for key in keys {
            let a = try JSONSerialization.data(withJSONObject: [left[key] ?? NSNull()], options: .sortedKeys)
            let b = try JSONSerialization.data(withJSONObject: [right[key] ?? NSNull()], options: .sortedKeys)
            #expect(a == b, "\(key) differs")
        }
        try apply(streamed, [envelope(12, "notice", #"{"code":"late","severity":"info"}"#)])
        #expect((try state(streamed)["notices"] as? [Any])?.isEmpty == true)
    }

    @Test func replayedEventsAfterHelloOkAreApplied() throws {
        let module = try store()
        try apply(module, [
            envelope(5, "state.snapshot", #"{"mode":{"mode":"passive","phase":"idle"},"transcript":[],"levels":[],"notices":[],"overlayEnabled":true,"capabilities":[]}"#),
            envelope(9, "hello.ok", #"{"deviceId":"d","protocolVersion":1,"minClientVersion":1,"serverVersion":"t","replayed":true}"#),
            envelope(6, "notice", #"{"code":"missed_1","severity":"info"}"#),
            envelope(7, "mode.changed", #"{"mode":"answers","phase":"active"}"#),
            envelope(7, "mode.changed", #"{"mode":"recording","phase":"active"}"#),
            envelope(8, "ack", #"{"cmdId":"c1","ok":false,"code":"not_available"}"#),
        ])
        let state = try state(module)
        #expect(state["lastSeq"] as? Int == 7)
        #expect((state["mode"] as? [String: Any])?["mode"] as? String == "answers")
        #expect((state["notices"] as? [[String: Any]])?.first?["code"] as? String == "missed_1")
        #expect((state["lastError"] as? [String: Any])?["code"] as? String == "not_available")
    }

    @Test func transcriptDedupesByItemAndSpeakerAndKeepsTail() throws {
        let module = try store()
        var events = [
            envelope(1, "transcript.delta", #"{"itemId":"i1","speaker":"them","text":"Рас","isFinal":false}"#),
            envelope(2, "transcript.delta", #"{"itemId":"i1","speaker":"them","text":"Расскажите","isFinal":true}"#),
            envelope(3, "transcript.delta", #"{"itemId":"i1","speaker":"me","text":"Да","isFinal":true}"#),
        ]
        try apply(module, events)
        var transcript = try #require(try state(module)["transcript"] as? [[String: Any]])
        #expect(transcript.map { $0["text"] as? String } == ["Расскажите", "Да"])

        events = (0..<45).map { envelope(10 + $0, "transcript.delta", #"{"itemId":"n\#($0)","speaker":"them","text":"t","isFinal":true}"#) }
        try apply(module, events)
        transcript = try #require(try state(module)["transcript"] as? [[String: Any]])
        #expect(transcript.count == 40)
        #expect(transcript.first?["itemId"] as? String == "n5")
    }

    @Test func pointSelectionSegmentsAndHotkeys() throws {
        let module = try store()
        try apply(module, [
            envelope(1, "answer.started", #"{"answerId":"r1","trigger":"auto","startedAt":1}"#),
            envelope(2, "answer.delta", #"{"answerId":"r1","offset":0,"text":"Intro\n1. One\n2. Two","points":[{"pointId":"r1.0","index":0,"start":6,"end":12,"open":false},{"pointId":"r1.1","index":1,"start":13,"end":19,"open":true}]}"#),
        ])
        let segments = try #require(try module.run("return answerSegments(globalThis.state.answer);") as? [[String: Any]])
        #expect(segments.map { $0["kind"] as? String } == ["text", "point", "point"])
        #expect(segments.map { $0["text"] as? String } == ["Intro", "1. One", "2. Two"])
        #expect(try module.run("return pointText(globalThis.state.answer, 1);") as? String == "2. Two")
        try module.run("globalThis.state = applyLocal(globalThis.state, hotkeyAction(']', globalThis.state).local); return null;")
        #expect(try state(module)["selectedPoint"] as? Int == 0)
        try module.run("globalThis.state = applyLocal(globalThis.state, hotkeyAction('2', globalThis.state).local); return null;")
        #expect(try state(module)["selectedPoint"] as? Int == 1)
        try module.run("globalThis.state = applyLocal(globalThis.state, hotkeyAction('9', globalThis.state).local); return null;")
        #expect(try state(module)["selectedPoint"] as? Int == 1)
        #expect(try module.run("return hotkeyAction('a', globalThis.state);") as? [String: String] == ["command": "answer_now"])
        #expect(try module.run("return hotkeyAction('R', globalThis.state);") as? [String: String] == ["command": "reset_context"])
        #expect(try module.run("return hotkeyAction('x', globalThis.state);") is NSNull)
        let handled = try #require(try module.run("""
        return [
          shouldHandleHotkey({tagName: 'input'}),
          shouldHandleHotkey({tagName: 'TEXTAREA'}),
          shouldHandleHotkey({tagName: 'SELECT'}),
          shouldHandleHotkey({tagName: 'DIV', isContentEditable: true}),
          shouldHandleHotkey({tagName: 'BODY'}),
          shouldHandleHotkey(null)
        ];
        """) as? [Bool])
        #expect(handled == [false, false, false, false, true, true])
    }

    @Test func sessionTimerAndStateFollowSessionEvents() throws {
        let module = try store()
        #expect(try module.run("return sessionCommand(globalThis.state);") as? String == "session.start")
        #expect(try module.run("return hotkeyAction('s', globalThis.state);") is NSNull)
        try apply(module, [
            try ServerFixtures.json("session.started"),
            try ServerFixtures.json("bookmark.added"),
        ])
        var session = try #require(try state(module)["session"] as? [String: Any])
        #expect(session["sessionId"] as? String == "ses_2")
        #expect(session["stars"] as? Int == 1)
        #expect((session["lastBookmark"] as? [String: Any])?["kind"] as? String == "star")
        #expect(try module.run("return sessionCommand(globalThis.state);") as? String == "session.stop")
        #expect(try module.run("return hotkeyAction('S', globalThis.state);") as? [String: String] == ["command": "star_last"])
        #expect(try module.run("return sessionElapsed(globalThis.state.session.startedAt, globalThis.state.session.startedAt + 65999);") as? String == "01:05")
        #expect(try module.run("return sessionElapsed(0, 3723000);") as? String == "1:02:03")
        #expect(try module.run("return sessionElapsed(5000, 1000);") as? String == "00:00")
        #expect(try module.run("return sessionElapsed(undefined, 1000);") as? String == "—")

        try apply(module, [
            envelope(30, "state.snapshot", #"{"mode":{"mode":"answers","phase":"active"},"transcript":[],"levels":[],"notices":[],"session":{"sessionId":"ses_2","startedAt":1762700000012},"overlayEnabled":true,"capabilities":["session.stop"]}"#),
            try ServerFixtures.json("bookmark.removed").replacingOccurrences(of: #""seq": 22"#, with: #""seq": 31"#),
        ])
        session = try #require(try state(module)["session"] as? [String: Any])
        #expect(session["stars"] as? Int == 0)
        #expect((session["lastBookmark"] as? [String: Any])?["kind"] as? String == "removed")

        try apply(module, [envelope(32, "session.stopped", #"{"sessionId":"other","endedAt":1}"#)])
        #expect(try state(module)["session"] is [String: Any])
        try apply(module, [envelope(33, "session.stopped", #"{"sessionId":"ses_2","endedAt":2,"reason":"user"}"#)])
        #expect(try state(module)["session"] is NSNull)
        #expect(try module.run("return sessionCommand(globalThis.state);") as? String == "session.start")
    }

    @Test func protocolModuleBuildsCommandsWithGetRandomValues() throws {
        let prelude = "globalThis.crypto = { getRandomValues: function (array) { for (var i = 0; i < array.length; i++) { array[i] = i * 17; } return array; } };"
        let module = try WebModuleContext(modules: ["protocol.js"], prelude: prelude)
        let hello = try #require(try module.run("return helloCommand('tok', 42);") as? [String: Any])
        #expect(hello["name"] as? String == "hello")
        #expect(hello["v"] as? Int == 1)
        #expect((hello["cmdId"] as? String)?.hasPrefix("c-") == true)
        #expect((hello["args"] as? [String: Any])?["lastSeq"] as? Int == 42)
        let fresh = try #require(try module.run("return helloCommand('tok', null);") as? [String: Any])
        #expect((fresh["args"] as? [String: Any])?["lastSeq"] == nil)
        #expect(try module.run("return pairingCodeFromHash('#pair=AB%2DCD');") as? String == "AB-CD")
        #expect(try module.run("return pairingCodeFromHash('#other');") is NSNull)
        #expect(try module.run("return parseEnvelope('{\"v\":2,\"seq\":1,\"type\":\"pong\"}');") is NSNull)
        #expect(try module.run("return parseEnvelope('nope');") is NSNull)
        #expect(try module.run("return socketURL({protocol: 'http:', host: '192.168.1.5:47057'});") as? String == "ws://192.168.1.5:47057/ws")
        #expect((try module.run("return describeClose(4401);") as? [String: Any])?["forgetToken"] as? Bool == true)
    }

    @Test func bundleAvoidsSecureContextOnlyAndRemoteAPIs() throws {
        let forbidden = ["randomUUID", "crypto.subtle", "serviceWorker", "innerHTML", "outerHTML", "insertAdjacentHTML", "eval(", "new Function", "http://", "https://", "navigator.clipboard"]
        for name in CompanionWebAssets.files.keys.sorted() {
            let source = try #require(CompanionWebAssets.text(named: name))
            for token in forbidden {
                #expect(!source.contains(token), "\(name) contains \(token)")
            }
        }
        let html = try #require(CompanionWebAssets.text(named: "index.html"))
        #expect(!html.contains(" style="))
        #expect(html.range(of: #"\son[a-z]+="#, options: .regularExpression) == nil)
        let scripts = html.components(separatedBy: "<script").dropFirst()
        #expect(scripts.count == 1)
        for script in scripts {
            #expect(script.contains(#"type="module""#))
            #expect(script.contains(#"src="/app.js""#))
            #expect(script.contains("></script>"))
        }
    }
}
