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
        let primary = app.segmentedControls["liveAppleLanguage"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        primary.buttons["English"].tap()
        XCTAssertTrue(primary.buttons["English"].isSelected)
        primary.buttons["中文"].tap()
        XCTAssertTrue(primary.buttons["中文"].isSelected)
        XCTAssertTrue(app.buttons["字幕模式"].exists)
        XCTAssertTrue(app.buttons["開啟子母字幕"].exists)
        app.buttons["錄音設定"].tap()
        for _ in 0..<8 {
            if app.sliders["pipFontScale"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.sliders["pipFontScale"].waitForExistence(timeout: 5))
        app.sliders["pipFontScale"].adjust(toNormalizedSliderPosition: 0.7)
        XCTAssertTrue(app.buttons["在子母畫面中預覽"].exists)
        XCTAssertTrue(app.buttons["還原子母字幕預設設定"].exists)
        for _ in 0..<8 {
            if app.buttons["準備語音資源"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["準備語音資源"].waitForExistence(timeout: 5))
        for _ in 0..<4 {
            if app.descendants(matching: .any)["recordingQuality"].firstMatch.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.descendants(matching: .any)["recordingQuality"].firstMatch.exists,
                      "Recording settings must expose storage quality")
        for _ in 0..<8 {
            if app.buttons["檢查更新"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["檢查更新"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.buttons["歷史紀錄"].tap()
        XCTAssertTrue(app.staticTexts["還沒有已儲存的課堂"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["匯入音訊"].exists)
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["開始錄音"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
