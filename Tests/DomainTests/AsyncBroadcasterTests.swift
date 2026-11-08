import Foundation
import Testing
@testable import Domain

private actor Collected<T: Sendable> {
    var items: [T] = []
    func append(_ item: T) { items.append(item) }
}

private func collect<T: Sendable>(_ stream: AsyncStream<T>, count: Int) async -> [T] {
    var out: [T] = []
    for await item in stream {
        out.append(item)
        if out.count == count { break }
    }
    return out
}

@Suite struct AsyncBroadcasterTests {
    @Test func threeSubscribersReceiveAllInOrder() async {
        let broadcaster = AsyncBroadcaster<Int>()
        let streams = (0..<3).map { broadcaster.subscribe("s\($0)") }
        for i in 0..<100 { broadcaster.yield(i) }
        for stream in streams {
            #expect(await collect(stream, count: 100) == Array(0..<100))
        }
    }

    @Test func slowSubscriberDropsOnlyItsOwn() async {
        let broadcaster = AsyncBroadcaster<Int>()
        let fast = broadcaster.subscribe("fast")
        let slow = broadcaster.subscribe("slow", policy: .bufferingNewest(2))
        for i in 0..<50 { broadcaster.yield(i) }
        #expect(await collect(fast, count: 50) == Array(0..<50))
        #expect(await collect(slow, count: 2) == [48, 49])
        #expect(broadcaster.droppedCount(for: "slow") == 48)
        #expect(broadcaster.droppedCount(for: "fast") == 0)
    }

    @Test func lateSubscriberGetsReplayLatest() async {
        let broadcaster = AsyncBroadcaster<String>(replayLatest: true, initial: "initial")
        broadcaster.yield("a")
        broadcaster.yield("b")
        let late = broadcaster.subscribe("late")
        broadcaster.yield("c")
        #expect(await collect(late, count: 2) == ["b", "c"])
    }

    @Test func replayDisabledByDefault() async {
        let broadcaster = AsyncBroadcaster<Int>()
        broadcaster.yield(1)
        let late = broadcaster.subscribe("late")
        broadcaster.yield(2)
        #expect(await collect(late, count: 1) == [2])
    }

    @Test func cancelledIteratorUnsubscribes() async throws {
        let broadcaster = AsyncBroadcaster<Int>()
        let stream = broadcaster.subscribe("temp")
        #expect(broadcaster.subscriberCount == 1)
        let task = Task { for await _ in stream {} }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        _ = await task.value
        for _ in 0..<50 where broadcaster.subscriberCount > 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(broadcaster.subscriberCount == 0)
    }

    @Test func finishClosesAll() async {
        let broadcaster = AsyncBroadcaster<Int>()
        let a = broadcaster.subscribe("a")
        let b = broadcaster.subscribe("b")
        broadcaster.yield(1)
        broadcaster.finish()
        var aItems: [Int] = []
        for await x in a { aItems.append(x) }
        var bItems: [Int] = []
        for await x in b { bItems.append(x) }
        #expect(aItems == [1])
        #expect(bItems == [1])
        #expect(broadcaster.subscriberCount == 0)
    }

    @Test func subscribeAfterFinishReturnsFinishedStream() async {
        let broadcaster = AsyncBroadcaster<Int>(replayLatest: true, initial: 7)
        broadcaster.finish()
        var items: [Int] = []
        for await x in broadcaster.subscribe("after") { items.append(x) }
        #expect(items.isEmpty)
    }

    @Test func concurrentSubscribeAndYield() async {
        let broadcaster = AsyncBroadcaster<Int>()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<1000 {
                group.addTask {
                    if i.isMultiple(of: 3) {
                        let s = broadcaster.subscribe("c\(i)", policy: .bufferingNewest(1))
                        _ = s
                    } else {
                        broadcaster.yield(i)
                    }
                }
            }
        }
        #expect(broadcaster.latest != nil)
    }
}
