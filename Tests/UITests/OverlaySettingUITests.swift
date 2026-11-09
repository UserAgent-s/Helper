import XCTest

final class OverlaySettingUITests: XCTestCase {
    @MainActor
    func testOverlayToggleInAppearanceSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += [
            "-com.local.UserAgent057.settings.onboardingCompleted", "YES",
            "-com.local.UserAgent057.settings.appLanguage", "ru",
            "-com.local.UserAgent057.overlay.enabled", "YES",
        ]
        app.launch()
        defer { app.terminate() }

        let openSettings = app.buttons["main.openSettings"]
        XCTAssertTrue(openSettings.waitForExistence(timeout: 10))
        openSettings.click()

        let appearanceTab = app.radioButtons["Внешний вид"].firstMatch
        XCTAssertTrue(appearanceTab.waitForExistence(timeout: 5))
        appearanceTab.click()

        let toggle = app.checkBoxes["settings.overlayEnabled"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? Int, 1)
        toggle.click()
        XCTAssertEqual(toggle.value as? Int, 0)
        toggle.click()
        XCTAssertEqual(toggle.value as? Int, 1)
    }
}
