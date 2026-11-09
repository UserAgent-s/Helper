import XCTest

final class PairingWindowUITests: XCTestCase {
    @MainActor
    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-com.local.UserAgent057.settings.onboardingCompleted", "YES"]
        app.launch()
        return app
    }

    @MainActor
    func testPairingWindowIsNotShownOnLaunch() {
        let app = launchApp()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["pairing.close"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testOpenPairingFromMenuAndCloseWithEscape() {
        let app = launchApp()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("p", modifierFlags: [.command, .shift])
        let close = app.buttons["pairing.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: close)
        waitForExpectations(timeout: 5)
    }
}
