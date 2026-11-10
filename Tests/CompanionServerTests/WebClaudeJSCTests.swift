import CompanionServer
import Foundation
import Testing

@Suite struct WebClaudeJSCTests {
    private func module() throws -> WebModuleContext {
        let module = try WebModuleContext(modules: ["claude.js"])
        try module.run("globalThis.deep = initialDeep(); return null;")
        return module
    }

    private func local(_ module: WebModuleContext, _ action: String) throws {
        try module.run("globalThis.deep = deepLocal(globalThis.deep, \(action)); return null;")
    }

    private func event(_ module: WebModuleContext, _ type: String, _ data: String) throws {
        try module.run("globalThis.deep = applyDeep(globalThis.deep, {v:1, seq:1, ts:0, type:\"\(type)\", data:\(data)}); return null;")
    }

    private func deep(_ module: WebModuleContext) throws -> [String: Any] {
        try #require(try module.run("return globalThis.deep;") as? [String: Any])
    }

    private func entries(_ module: WebModuleContext) throws -> [[String: Any]] {
        try #require(try deep(module)["entries"] as? [[String: Any]])
    }

    @Test func pointExpansionStreamsAndCompletesWithStats() throws {
        let m = try module()
        try local(m, #"{type:"format", value:"short"}"#)
        let args = try #require(try m.run(#"return deepCommandArgs(globalThis.deep, {pointId:"r1.0"});"#) as? [String: Any])
        #expect(args["pointId"] as? String == "r1.0")
        #expect(args["format"] as? String == "short")
        #expect(args["language"] as? String == "auto")
        #expect(args["model"] == nil)
        try local(m, #"{type:"requested", cmdId:"c1", args:{pointId:"r1.0", format:"short"}, pointNumber:0}"#)
        #expect((try deep(m)["pending"] as? [Any])?.count == 1)
        #expect(try deep(m)["open"] as? Bool == true)

        try event(m, "deep.started", #"{"requestId":"exp-1","pointId":"r1.0","model":"sonnet","format":"short","language":"auto"}"#)
        var list = try entries(m)
        #expect(list.count == 1)
        #expect(list[0]["status"] as? String == "thinking")
        #expect(list[0]["pointNumber"] as? Int == 0)
        #expect((try deep(m)["pending"] as? [Any])?.isEmpty == true)
        #expect(try deep(m)["activeId"] as? String == "exp-1")

        try event(m, "deep.delta", #"{"requestId":"exp-1","offset":0,"text":"Я строил "}"#)
        list = try entries(m)
        #expect(list[0]["status"] as? String == "streaming")
        #expect(list[0]["text"] as? String == "Я строил ")
        try event(m, "deep.delta", #"{"requestId":"exp-1","offset":9,"text":"шлюз."}"#)
        try event(m, "deep.delta", #"{"requestId":"exp-1","offset":9,"text":"шлюз."}"#)
        #expect(try entries(m)[0]["text"] as? String == "Я строил шлюз.")

        try event(m, "deep.done", #"{"requestId":"exp-1","status":"completed","ttftMs":820,"costUsd":0.0061,"modelId":"claude-sonnet-5-5"}"#)
        list = try entries(m)
        #expect(list[0]["status"] as? String == "completed")
        #expect(try m.run("return deepStatsText(globalThis.deep.entries[0]);") as? String == "первый текст через 0.8 с · $0.0061 · claude-sonnet-5-5")
        #expect(try m.run("return canFollowUp(globalThis.deep);") as? Bool == true)
    }

    @Test func repeatedClickOnSamePointIsDeduplicatedWhileRunning() throws {
        let m = try module()
        #expect(try m.run(#"return canExpand(globalThis.deep, {pointId:"r1.0"});"#) as? Bool == true)
        try local(m, #"{type:"requested", cmdId:"c1", args:{pointId:"r1.0"}, pointNumber:0}"#)
        #expect(try m.run(#"return canExpand(globalThis.deep, {pointId:"r1.0"});"#) as? Bool == false)
        #expect(try m.run(#"return canExpand(globalThis.deep, {pointId:"r1.1"});"#) as? Bool == true)
        try event(m, "deep.started", #"{"requestId":"exp-1","pointId":"r1.0","model":"sonnet","format":"structured","language":"auto"}"#)
        #expect(try m.run(#"return canExpand(globalThis.deep, {pointId:"r1.0"});"#) as? Bool == false)
        #expect((try m.run(#"return runningEntryForPoint(globalThis.deep, "r1.0").requestId;"#) as? String) == "exp-1")
        try event(m, "deep.started", #"{"requestId":"exp-1","pointId":"r1.0","model":"sonnet","format":"structured","language":"auto"}"#)
        #expect(try entries(m).count == 1)
        try event(m, "deep.done", #"{"requestId":"exp-1","status":"completed"}"#)
        #expect(try m.run(#"return canExpand(globalThis.deep, {pointId:"r1.0"});"#) as? Bool == true)
    }

    @Test func refusalIsExplicitAndNotFollowable() throws {
        let m = try module()
        try local(m, #"{type:"requested", cmdId:"c1", args:{freeText:"вопрос"}}"#)
        try event(m, "deep.started", #"{"requestId":"exp-9","model":"sonnet","format":"structured","language":"auto"}"#)
        #expect(try entries(m)[0]["question"] as? String == "вопрос")
        try event(m, "deep.delta", #"{"requestId":"exp-9","offset":0,"text":"Частич"}"#)
        try event(m, "deep.done", #"{"requestId":"exp-9","status":"failed","errorCode":"refused_cyber"}"#)
        let entry = try entries(m)[0]
        #expect(entry["refused"] as? Bool == true)
        #expect(try m.run("return deepErrorText(globalThis.deep.entries[0].errorCode);") as? String == "Claude отказался отвечать (cyber). Переформулируйте вопрос.")
        #expect(try m.run("return canFollowUp(globalThis.deep);") as? Bool == false)
        #expect(try m.run(#"return deepErrorText("max_tokens");"#) as? String == "Ответ обрезан по лимиту длины.")
    }

    @Test func followUpArgsCarryOnlyParentAndQuestion() throws {
        let m = try module()
        let args = try #require(try m.run(#"globalThis.deep = deepLocal(globalThis.deep, {type:"model", value:"opus"}); return deepCommandArgs(globalThis.deep, {parentRequestId:"exp-1", freeText:"А ограничения?"});"#) as? [String: Any])
        #expect(args.count == 2)
        #expect(args["parentRequestId"] as? String == "exp-1")
        let fresh = try #require(try m.run(#"return deepCommandArgs(globalThis.deep, {freeText:"x"});"#) as? [String: Any])
        #expect(fresh["model"] as? String == "opus")
        try local(m, #"{type:"requested", cmdId:"c2", args:{parentRequestId:"exp-1", freeText:"А ограничения?"}}"#)
        try event(m, "deep.started", #"{"requestId":"exp-2","model":"opus","format":"structured","language":"auto"}"#)
        #expect(try entries(m)[0]["parentRequestId"] as? String == "exp-1")
        #expect(try m.run("return deepTitle(globalThis.deep.entries[0]);") as? String == "Уточнение: А ограничения?")
    }

    @Test func rejectionSnapshotAndReconnectReleasePending() throws {
        let m = try module()
        try local(m, #"{type:"requested", cmdId:"c1", args:{pointId:"r1.0"}}"#)
        try local(m, #"{type:"rejected", cmdId:"c1", code:"claude_unavailable"}"#)
        #expect((try deep(m)["pending"] as? [Any])?.isEmpty == true)
        #expect(try deep(m)["lastError"] as? String == "claude_unavailable")
        try local(m, #"{type:"requested", cmdId:"c2", args:{pointId:"r1.0"}}"#)
        try local(m, #"{type:"online"}"#)
        #expect(try m.run(#"return canExpand(globalThis.deep, {pointId:"r1.0"});"#) as? Bool == true)
        try event(m, "deep.started", #"{"requestId":"exp-3","pointId":"r1.0","model":"sonnet","format":"structured","language":"auto"}"#)
        try local(m, #"{type:"snapshot"}"#)
        let entry = try entries(m)[0]
        #expect(entry["status"] as? String == "failed")
        #expect(entry["errorCode"] as? String == "interrupted")
        #expect(try m.run(#"return canExpand(globalThis.deep, {pointId:"r1.0"});"#) as? Bool == true)
    }

    @Test func deltaGapIsFlaggedAndUnknownRequestIgnored() throws {
        let m = try module()
        try event(m, "deep.delta", #"{"requestId":"nope","offset":0,"text":"x"}"#)
        #expect(try entries(m).isEmpty)
        try event(m, "deep.started", #"{"requestId":"exp-1","model":"sonnet","format":"structured","language":"auto"}"#)
        try event(m, "deep.delta", #"{"requestId":"exp-1","offset":5,"text":"x"}"#)
        #expect(try entries(m)[0]["gap"] as? Bool == true)
    }

    @Test func entriesAreCappedKeepingRunningOnes() throws {
        let m = try module()
        try event(m, "deep.started", #"{"requestId":"run","model":"sonnet","format":"structured","language":"auto"}"#)
        for index in 0..<10 {
            try event(m, "deep.started", #"{"requestId":"e\#(index)","model":"sonnet","format":"structured","language":"auto"}"#)
            try event(m, "deep.done", #"{"requestId":"e\#(index)","status":"completed"}"#)
        }
        let ids = try entries(m).compactMap { $0["requestId"] as? String }
        #expect(ids.count == 8)
        #expect(ids.contains("run"))
        #expect(ids.last == "e9")
    }

    @Test func fixturesDecodeIntoEntries() throws {
        let m = try module()
        for type in ["deep.started", "deep.delta", "deep.done"] {
            m.set("fixture", json: try ServerFixtures.json(type))
            try m.run("globalThis.deep = applyDeep(globalThis.deep, fixture); return null;")
        }
        #expect(try entries(m).count == 1)
        #expect(m.exceptions.isEmpty)
    }

    @Test func storeHotkeysExpandSelectedOrLastAndEscapeCloses() throws {
        let store = try WebModuleContext(modules: ["store.js"])
        let withPoints = #"var s = initialState(); s.capabilities = ["expand"]; s.answer = {answerId:"r1", trigger:"automatic", status:"completed", text:"- a\n- b\n", points:[{pointId:"r1.0",index:0,start:2,end:3,open:false},{pointId:"r1.1",index:1,start:6,end:7,open:false}]};"#
        #expect(try store.run(withPoints + #"return hotkeyAction("e", s).expand;"#) as? Int == 1)
        #expect(try store.run(withPoints + #"s.selectedPoint = 0; return hotkeyAction("E", s).expand;"#) as? Int == 0)
        #expect(try store.run(withPoints + #"return pointIdAt(s.answer, 1);"#) as? String == "r1.1")
        #expect(try store.run(#"var s = initialState(); return hotkeyAction("e", s);"#) is NSNull)
        #expect(try store.run(#"var s = initialState(); return hotkeyAction("Escape", s).deepClose;"#) as? Bool == true)
        #expect(CompanionWebAssets.asset(forPath: "/claude.js")?.contentType == "text/javascript; charset=utf-8")
    }
}

@Suite struct WebTranslationJSCTests {
    @Test func tTogglesTranslationAndLineKeepsTranslation() throws {
        let store = try WebModuleContext(modules: ["store.js"])
        #expect(try store.run(#"var s = initialState(); return s.showTranslation;"#) as? Bool == true)
        #expect(try store.run(#"var s = initialState(); return applyLocal(s, hotkeyAction("t", s).local).showTranslation;"#) as? Bool == false)
        let line = try store.run(#"var s = initialState(); s = applyEnvelope(s, {v:1, seq:1, ts:0, type:"transcript.delta", data:{itemId:"i1", speaker:"them", text:"Why?", isFinal:true}}); s = applyEnvelope(s, {v:1, seq:2, ts:0, type:"transcript.delta", data:{itemId:"i1", speaker:"them", text:"Why?", isFinal:true, translation:"Почему?"}}); return s.transcript;"#) as? [[String: Any]]
        #expect(line?.count == 1)
        #expect(line?.first?["translation"] as? String == "Почему?")
    }
}

@Suite struct WebScreenJSCTests {
    @Test func screenHotkeysAndCapturesReducer() throws {
        let store = try WebModuleContext(modules: ["store.js"])
        #expect(try store.run(#"var s = initialState(); return hotkeyAction("x", s);"#) is NSNull)
        let capture = try #require(try store.run(#"var s = initialState(); s.capabilities = ["capture_screen"]; return hotkeyAction("x", s);"#) as? [String: Any])
        #expect(capture["command"] as? String == "capture_screen")
        let ask = try #require(try store.run(#"var s = initialState(); s.capabilities = ["capture_screen"]; return hotkeyAction("Z", s).args;"#) as? [String: Any])
        #expect(ask["ask"] as? Bool == true)
        let captures = try #require(try store.run(#"var s = initialState(); for (var i = 0; i < 7; i++) { s = applyEnvelope(s, {v:1, seq:i+1, ts:0, type:"screen.captured", data:{captureId:"c"+i, capturedAt:0, charCount:3, text:"abc"}}); } s = applyEnvelope(s, {v:1, seq:9, ts:0, type:"screen.captured", data:{captureId:"c6", capturedAt:0, charCount:3}}); return s.captures.map(function(c){return c.captureId;});"#) as? [String])
        #expect(captures == ["c6", "c5", "c4", "c3", "c2"])
    }
}
