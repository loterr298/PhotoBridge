import XCTest

/// Actual simulator UI, no demo photos, no Photos writes, no fake USB state.
final class PhotoBridgeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
    }
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testTaskNavigationAndEmptyReceive() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["在 Mac 上开始"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["等待 Mac 连接"].exists)
        XCTAssertFalse(app.staticTexts["Mac 已连接 · USB"].exists)
        capture("iPhone-export-light", app: app)
        app.tabBars.buttons["导入到 iPhone"].tap()
        XCTAssertTrue(app.staticTexts["等待 Mac 连接"].exists)
        XCTAssertTrue(app.buttons["查找收到的照片"].waitForExistence(timeout: 10))
        app.buttons["查找收到的照片"].tap()
        XCTAssertTrue(app.staticTexts["先在 Mac 选择相册文件夹并发送。"].waitForExistence(timeout: 10))
        capture("iPhone-import-empty-light", app: app)
        app.tabBars.buttons["照片信息"].tap()
        XCTAssertTrue(app.buttons["选择原始照片"].waitForExistence(timeout: 10))
        capture("iPhone-photo-info-light", app: app)
        app.tabBars.buttons["导出到 Mac"].tap()
        XCTAssertTrue(app.staticTexts["在 Mac 上开始"].waitForExistence(timeout: 10))
    }
    func testSystemPhotoPickerCanCancel() throws {
        let app = launch()
        app.tabBars.buttons["照片信息"].tap()
        app.buttons["选择原始照片"].tap()
        let chinese = app.buttons["取消"].firstMatch
        let english = app.buttons["Cancel"].firstMatch
        if chinese.waitForExistence(timeout: 10) { chinese.tap() }
        else {
            XCTAssertTrue(english.waitForExistence(timeout: 10))
            english.tap()
        }
        XCTAssertTrue(app.buttons["选择原始照片"].waitForExistence(timeout: 10))
        capture("iPhone-photo-picker-cancelled", app: app)
    }
}
