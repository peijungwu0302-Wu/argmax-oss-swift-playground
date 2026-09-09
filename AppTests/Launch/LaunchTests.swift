import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testInitialScreenAndHistory() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["開始錄音"].waitForExistence(timeout: 30), "App must show its controls without loading a model")
        XCTAssertTrue(app.textFields["課堂名稱"].exists)
        XCTAssertTrue(app.staticTexts["即時逐字稿"].exists)
        XCTAssertTrue(app.switches["translationToggle"].exists)
        let primary = app.segmentedControls["mixedPrimaryLanguage"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        primary.buttons["英文為主"].tap()
        XCTAssertTrue(primary.buttons["英文為主"].isSelected)
        primary.buttons["中文為主"].tap()
        XCTAssertTrue(primary.buttons["中文為主"].isSelected)
        XCTAssertTrue(app.buttons["字幕模式"].exists)
        app.buttons["錄音設定"].tap()
        XCTAssertTrue(app.buttons["載入模型"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.buttons["歷史紀錄"].tap()
        XCTAssertTrue(app.staticTexts["還沒有已儲存的課堂"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["開始錄音"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
