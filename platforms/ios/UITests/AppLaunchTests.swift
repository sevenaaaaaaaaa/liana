import XCTest

/// Runs the actual app process and scene connection. Controller-only unit tests
/// cannot detect a missing UIApplicationSceneManifest or scene delegate.
final class AppLaunchTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testColdLaunchAndRelaunch() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["松萝输入法"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.buttons["mac.open"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["松萝输入法"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testMacInboxAfterSceneConnects() {
        let app = XCUIApplication()
        app.launch()
        let inbox = app.buttons["mac.open"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 15))
        inbox.tap()
        XCTAssertTrue(app.staticTexts["把文件交给 Mac 桌宠"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["mac.scan"].exists)
        XCTAssertTrue(app.buttons["mac.paste"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }
    func testMobileToolsOpenWithoutStartingMicrophone() {
        let app = XCUIApplication()
        app.launch()
        let tools=app.buttons["mobile.tools"]
        XCTAssertTrue(tools.waitForExistence(timeout:15)); tools.tap()
        XCTAssertTrue(app.buttons["voice.start"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["voice.copy"].exists)
        let screenshot=XCTAttachment(screenshot:app.screenshot()); screenshot.name="iPhone-mobile-tools"; screenshot.lifetime = .keepAlways; add(screenshot)
        XCTAssertEqual(app.state,.runningForeground)
    }

}
