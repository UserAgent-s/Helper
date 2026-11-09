import Foundation
import Testing

@Suite struct WebConnectionJSCTests {
    static let prelude = """
    globalThis.crypto = { getRandomValues: function (array) { for (var i = 0; i < array.length; i++) { array[i] = i; } return array; } };
    globalThis.clock = {
      now: 0, nextId: 1, tasks: [],
      setTimeout: function (callback, delay) { var id = this.nextId++; this.tasks.push({ id: id, at: this.now + delay, callback: callback }); return id; },
      clearTimeout: function (id) { this.tasks = this.tasks.filter(function (task) { return task.id !== id; }); },
      advance: function (ms) {
        var target = this.now + ms;
        while (true) {
          var due = this.tasks.filter(function (task) { return task.at <= target; }).sort(function (a, b) { return a.at - b.at || a.id - b.id; });
          if (due.length === 0) { break; }
          var task = due[0];
          this.tasks = this.tasks.filter(function (other) { return other.id !== task.id; });
          this.now = task.at;
          task.callback();
        }
        this.now = target;
      }
    };
    globalThis.log = [];
    globalThis.makeSupervisor = function (randomValue) {
      return createSupervisor({
        timers: { setTimeout: function (f, ms) { return clock.setTimeout(f, ms); }, clearTimeout: function (id) { clock.clearTimeout(id); } },
        random: function () { return randomValue; },
        connect: function () { log.push("connect@" + clock.now); },
        ping: function () { log.push("ping@" + clock.now); },
        drop: function () { log.push("drop@" + clock.now); },
        onSilence: function (value) { log.push("silent:" + value + "@" + clock.now); }
      });
    };
    """

    private func module() throws -> WebModuleContext {
        try WebModuleContext(modules: ["protocol.js", "connection.js"], prelude: Self.prelude)
    }

    private func log(_ module: WebModuleContext) throws -> [String] {
        try #require(try module.run("return log;") as? [String])
    }

    @Test func backoffStepsWithBoundedJitter() throws {
        let module = try module()
        let middle = try #require(try module.run("return [0,1,2,3,4,5,9].map(function (a) { return backoffDelay(a, 0.5); });") as? [Int])
        #expect(middle == [500, 1000, 2000, 4000, 5000, 5000, 5000])
        let low = try #require(try module.run("return [0,4].map(function (a) { return backoffDelay(a, 0); });") as? [Int])
        let high = try #require(try module.run("return [0,4].map(function (a) { return backoffDelay(a, 1); });") as? [Int])
        #expect(low == [400, 4000])
        #expect(high == [600, 6000])
        let ping = try #require(try module.run("return pingCommand();") as? [String: Any])
        #expect(ping["name"] as? String == "ping")
        #expect(((ping["args"] as? [String: Any])?["nonce"] as? String)?.hasPrefix("n-") == true)
    }

    @Test func reconnectsOnBackoffScheduleAndResetsAfterHello() throws {
        let module = try module()
        try module.run("globalThis.s = makeSupervisor(0.5); s.start(); return null;")
        var delays: [Int] = []
        for _ in 0..<6 {
            delays.append(try #require(try module.run("var d = s.closed(true); clock.advance(d); return d;") as? Int))
        }
        #expect(delays == [500, 1000, 2000, 4000, 5000, 5000])
        let connects = try log(module).filter { $0.hasPrefix("connect@") }
        #expect(connects == ["connect@0", "connect@500", "connect@1500", "connect@3500", "connect@7500", "connect@12500", "connect@17500"])
        try module.run("s.authenticated(); return null;")
        #expect(try module.run("return s.closed(true);") as? Int == 500)
        #expect(try module.run("return s.closed(false);") is NSNull)
    }

    @Test func pingsEveryTenSecondsWhileLiveAndSilenceDropsAfterTwenty() throws {
        let module = try module()
        try module.run("globalThis.s = makeSupervisor(0.5); s.start(); s.authenticated(); return null;")
        for _ in 0..<5 {
            try module.run("clock.advance(5000); s.heard(); return null;")
        }
        var events = try log(module)
        #expect(events.filter { $0.hasPrefix("ping@") } == ["ping@10000", "ping@20000"])
        #expect(!events.contains { $0.hasPrefix("silent") || $0.hasPrefix("drop") })

        try module.run("clock.advance(19999); return null;")
        #expect(try log(module).filter { $0.hasPrefix("silent") }.isEmpty)
        try module.run("clock.advance(1); return null;")
        events = try log(module)
        #expect(events.suffix(2) == ["silent:true@45000", "drop@45000"])
        #expect(try module.run("return s.silent;") as? Bool == true)
        try module.run("s.authenticated(); return null;")
        #expect(try log(module).last == "silent:false@45000")
    }

    @Test func outageRaisesBannerTwentySecondsAfterLastMessageWhileRetrying() throws {
        let module = try module()
        try module.run("globalThis.s = makeSupervisor(0.5); s.start(); s.authenticated(); clock.advance(3000); s.heard(); return null;")
        try module.run("""
        var d = s.closed(true);
        for (var i = 0; i < 8; i++) { clock.advance(d); d = s.closed(true); }
        return null;
        """)
        let events = try log(module)
        let silence = events.filter { $0.hasPrefix("silent") }
        #expect(silence == ["silent:true@23000"])
        #expect(!events.contains { $0.hasPrefix("drop") })
        #expect(events.filter { $0.hasPrefix("connect@") }.count > 4)
    }

    @Test func wakeReconnectsImmediatelyAndStopCancelsTimers() throws {
        let module = try module()
        try module.run("globalThis.s = makeSupervisor(0.5); s.start(); s.authenticated(); s.closed(true); s.closed(true); s.closed(true); clock.advance(100); s.wake(); return null;")
        #expect(try log(module).last == "connect@100")
        #expect(try module.run("return s.attempt;") as? Int == 0)
        try module.run("s.stop(); globalThis.log = []; clock.advance(60000); return null;")
        #expect(try log(module).isEmpty)
        #expect(try module.run("return clock.tasks.length;") as? Int == 0)
    }
}
