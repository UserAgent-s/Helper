import XCTest

final class SessionMenuBarUITests: XCTestCase {
    @MainActor
    func testSessionStartStopFromMenuBar() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += [
            "-com.local.UserAgent057.settings.onboardingCompleted", "YES",
            "-com.local.UserAgent057.settings.appLanguage", "ru",
        ]
        app.launch()
        defer { app.terminate() }

        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10))
        let windowsBefore = app.windows.count

        statusItem.click()
        let start = app.menuItems["Начать сессию"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["Отметить момент"].isEnabled)
        start.click()

        statusItem.click()
        let stop = app.menuItems["Остановить сессию"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertTrue(app.menuItems["Отметить момент"].isEnabled)
        stop.click()

        statusItem.click()
        XCTAssertTrue(app.menuItems["Начать сессию"].waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertEqual(app.dialogs.count, 0)
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertEqual(app.windows.count, windowsBefore)
    }
}
