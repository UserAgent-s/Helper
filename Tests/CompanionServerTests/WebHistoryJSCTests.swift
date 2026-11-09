import CompanionServer
import Foundation
import Testing

@Suite struct WebHistoryJSCTests {
    private func module() throws -> WebModuleContext {
        let module = try WebModuleContext(modules: ["history.js"])
        try module.run("globalThis.h = initialHistory(); return null;")
        return module
    }

    private func local(_ module: WebModuleContext, _ action: String) throws {
        try module.run("globalThis.h = historyLocal(globalThis.h, \(action)); return null;")
    }

    private func apply(_ module: WebModuleContext, _ envelope: String) throws {
        module.set("incoming", json: envelope)
        try module.run("globalThis.h = applyHistory(globalThis.h, incoming); return null;")
    }

    private func history(_ module: WebModuleContext) throws -> [String: Any] {
        try #require(try module.run("return globalThis.h;") as? [String: Any])
    }

    private func page(q: String? = nil, cursor: String? = nil, ids: [String], next: String? = nil) -> String {
        var data: [String: Any] = ["items": ids.map { ["sessionId": $0, "kind": "assistant", "startedAt": 1] }]
        if let q { data["q"] = q }
        if let cursor { data["cursor"] = cursor }
        if let next { data["nextCursor"] = next }
        let envelope: [String: Any] = ["v": 1, "seq": 9, "ts": 1, "type": "history.page", "data": data]
        return String(decoding: try! JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
    }

    private func ids(_ module: WebModuleContext) throws -> [String] {
        try #require(try module.run("return globalThis.h.items.map(function (i) { return i.sessionId; });") as? [String])
    }

    @Test func historyReducerPagesSearchesAndIgnoresStaleResponses() throws {
        let module = try module()
        try local(module, #"{ type: "open" }"#)
        try local(module, #"{ type: "requestList", more: false }"#)
        #expect(try module.run("return historyListArgs(globalThis.h);") as? [String: Int] == ["limit": 50])
        try apply(module, page(ids: ["a", "b"], next: "cur1"))
        #expect(try ids(module) == ["a", "b"])
        #expect(try history(module)["loading"] as? Bool == false)

        try local(module, #"{ type: "requestList", more: true }"#)
        #expect(try module.run("return historyListArgs(globalThis.h).cursor;") as? String == "cur1")
        try apply(module, page(ids: ["x"]))
        #expect(try ids(module) == ["a", "b"])
        try apply(module, page(cursor: "cur1", ids: ["b", "c"]))
        #expect(try ids(module) == ["a", "b", "c"])
        #expect(try history(module)["nextCursor"] is NSNull)

        try local(module, #"{ type: "query", text: "  kafka " }"#)
        try local(module, #"{ type: "requestList", more: true }"#)
        #expect(try module.run("return historyListArgs(globalThis.h);") as? [String: AnyHashable] == ["limit": 50, "q": "kafka"])
        try apply(module, page(ids: ["old"]))
        #expect(try ids(module) == ["a", "b", "c"])
        try apply(module, page(q: "kafka", ids: ["k"]))
        #expect(try ids(module) == ["k"])
        try apply(module, page(q: "kafka", ids: ["late"]))
        #expect(try ids(module) == ["k"])
    }

    @Test func historyDetailOnlyForSelectedSessionAndKeepsGroupedExpansions() throws {
        let module = try module()
        let fixture = try ServerFixtures.json("history.session")
        try apply(module, fixture)
        #expect(try history(module)["detail"] is NSNull)
        try local(module, #"{ type: "select", sessionId: "8F0C6B2A-3D4E-4F50-9A1B-2C3D4E5F6A7B" }"#)
        #expect(try history(module)["loadingDetail"] as? Bool == true)
        try apply(module, fixture)
        #expect(try history(module)["loadingDetail"] as? Bool == false)
        #expect(try module.run("return globalThis.h.detail.qa[0].expansions[0].expansionId;") as? String == "d1")
        #expect(try module.run("return formatOffset(globalThis.h.detail.startedAt, globalThis.h.detail.qa[0].askedAt);") as? String == "+01:00")
        try local(module, #"{ type: "failed", command: "history.get" }"#)
        try local(module, #"{ type: "back" }"#)
        #expect(try history(module)["selected"] is NSNull)
        #expect(try history(module)["detail"] is NSNull)
    }

    @Test func historyLabelsAndFailureReset() throws {
        let module = try module()
        #expect(try module.run(#"return itemTitle({ title: "Звонок", startedAt: 0 });"#) as? String == "Звонок")
        #expect(try module.run(#"return itemMeta({ startedAt: 0, qaCount: 2, starCount: 0 }).indexOf("Q&A 2") > 0;"#) as? Bool == true)
        #expect(try module.run(#"return hitLabel({ source: "screen_text" });"#) as? String == "экран")
        try local(module, #"{ type: "requestList", more: false }"#)
        try local(module, #"{ type: "failed", command: "history.list" }"#)
        #expect(try history(module)["loading"] as? Bool == false)
    }

    @Test func storeIgnoresHistoryEventsForSequenceTracking() throws {
        let module = try WebModuleContext(modules: ["store.js"])
        try module.run("globalThis.state = initialState(); return null;")
        module.set("env", json: try ServerFixtures.json("history.page"))
        try module.run("globalThis.state = applyEnvelope(globalThis.state, env); return null;")
        #expect(try module.run("return globalThis.state.lastSeq;") is NSNull)
    }

    @Test func historyModuleIsServed() {
        #expect(CompanionWebAssets.asset(forPath: "/history.js")?.contentType == "text/javascript; charset=utf-8")
        #expect(CompanionWebAssets.text(named: "index.html")?.contains("id=\"history-open\"") == true)
    }
}
