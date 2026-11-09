import XCTest

final class HistorySessionsUITests: XCTestCase {
    @MainActor
    func testHistorySessionsTabOpensDetail() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += [
            "-com.local.UserAgent057.settings.onboardingCompleted", "YES",
            "-com.local.UserAgent057.settings.appLanguage", "ru",
            "-UA057InMemoryStore",
        ]
        app.launch()
        defer { app.terminate() }

        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10))
        statusItem.click()
        let start = app.menuItems["Начать сессию"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.click()

        statusItem.click()
        let moment = app.menuItems["Отметить момент"]
        XCTAssertTrue(moment.waitForExistence(timeout: 10))
        moment.click()

        statusItem.click()
        let stop = app.menuItems["Остановить сессию"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.click()

        let openHistory = app.buttons["main.openHistory"]
        XCTAssertTrue(openHistory.waitForExistence(timeout: 10))
        openHistory.click()

        let sessionsTab = app.radioButtons["Сессии"].firstMatch
        XCTAssertTrue(sessionsTab.waitForExistence(timeout: 5))
        XCTAssertTrue(sessionsTab.isSelected)

        let row = app.descendants(matching: .any)["history.sessionRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()

        let title = app.staticTexts["history.sessionDetail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Отмеченное"].waitForExistence(timeout: 5))
    }
}
