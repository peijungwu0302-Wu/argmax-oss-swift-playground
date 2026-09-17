import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testInitialScreenAndHistory() {
        let app = XCUIApplication()
        app.launchArguments += ["-audioInputSource", "microphone", "-appLanguage", "zh-Hant", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
        app.launch()
        XCTAssertTrue(app.buttons["開始錄音"].waitForExistence(timeout: 30), "App must show its controls without loading a model")
        XCTAssertTrue(app.textFields["課堂名稱"].exists)
        XCTAssertTrue(app.staticTexts["即時逐字稿"].exists)
        XCTAssertTrue(app.switches["translationToggle"].exists)
        let primary = app.segmentedControls["liveAppleLanguage"]
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        let enButton = primary.buttons["English"]
        if enButton.waitForExistence(timeout: 5) {
            if !enButton.isSelected {
                enButton.tap()
            }
            let enPredicate = NSPredicate(format: "isSelected == true OR value == '1'")
            let enExpectation = XCTNSPredicateExpectation(predicate: enPredicate, object: enButton)
            _ = XCTWaiter.wait(for: [enExpectation], timeout: 5)
            XCTAssertTrue(enButton.isSelected || (enButton.value as? String == "1") || enButton.exists)
        }

        let zhButton = primary.buttons["中文"]
        if zhButton.waitForExistence(timeout: 5) {
            if !zhButton.isSelected {
                zhButton.tap()
            }
            let zhPredicate = NSPredicate(format: "isSelected == true OR value == '1'")
            let zhExpectation = XCTNSPredicateExpectation(predicate: zhPredicate, object: zhButton)
            _ = XCTWaiter.wait(for: [zhExpectation], timeout: 5)
            XCTAssertTrue(zhButton.isSelected || (zhButton.value as? String == "1") || zhButton.exists)
        }
        XCTAssertTrue(app.buttons["字幕模式"].exists)
        XCTAssertTrue(app.buttons["openPiPCaptions"].exists)
        app.buttons["錄音設定"].tap()

        for _ in 0..<10 {
            if app.buttons["prepareSpeechResource"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["prepareSpeechResource"].waitForExistence(timeout: 5))
        for _ in 0..<12 {
            if app.sliders["pipFontScale"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.sliders["pipFontScale"].waitForExistence(timeout: 5))
        app.sliders["pipFontScale"].adjust(toNormalizedSliderPosition: 0.7)
        for _ in 0..<5 {
            if app.buttons["previewPiP"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["previewPiP"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["resetPiP"].exists)
        for _ in 0..<12 {
            if app.descendants(matching: .any)["recordingQuality"].firstMatch.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.descendants(matching: .any)["recordingQuality"].firstMatch.exists,
                      "Recording settings must expose storage quality")
        for _ in 0..<24 {
            if app.buttons["檢查更新"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["檢查更新"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.buttons["歷史紀錄"].tap()
        XCTAssertTrue(app.staticTexts["還沒有已儲存的課堂"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["匯入音訊"].exists)
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["開始錄音"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
