import Foundation
@testable import Domain

func waitUntil(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

func settle(_ controller: AnswersModeController, _ realtime: FakeLiveResponder) async {
    await waitUntil {
        let emitted = await realtime.emittedEventCount
        return await controller.handledEventCountForTesting >= emitted
    }
}
