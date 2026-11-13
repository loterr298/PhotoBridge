import XCTest

/// Actual simulator UI, no demo photos, no Photos writes, no fake USB state.
final class PhotoBridgeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(resetPhotos: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if resetPhotos { app.resetAuthorizationStatus(for: .photos) }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
    }
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    @discardableResult
    private func handlePhotoPrompt(_ app: XCUIApplication, allow: Bool) -> NSObjectProtocol {
        addUIInterruptionMonitor(withDescription: "Photos permission") { alert in
            let full = alert.buttons.matching(NSPredicate(
                format: "label CONTAINS[c] 'full' OR label CONTAINS '完全' OR label CONTAINS '全部' OR label CONTAINS '所有'"
            )).firstMatch
            let deny = alert.buttons.matching(NSPredicate(
                format: "label CONTAINS[c] 'don't' OR label CONTAINS '不允许' OR label CONTAINS '不允許'"
            )).firstMatch
            if allow, full.exists { full.tap(); return true }
            if !allow, deny.exists { deny.tap(); return true }
            return false
        }
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
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.staticTexts["照片保护"].waitForExistence(timeout: 10))
        capture("iPhone-settings-light", app: app)
    }

    func testExportPermissionButtonPresentsSystemPrompt() throws {
        let app = launch(resetPhotos: true)
        let allow = app.buttons["exportPhotoPermission"]
        XCTAssertTrue(allow.waitForExistence(timeout: 15))
        let monitor = handlePhotoPrompt(app, allow: false)
        allow.tap()
        app.tap()
        XCTAssertTrue(app.staticTexts["正在请求照片权限…"].waitForExistence(timeout: 5) || app.buttons["exportPhotoPermission"].waitForExistence(timeout: 10), "Tapping the glass card button must show an immediate response")
        capture("iPhone-export-photos-system-prompt", app: app)
        XCTAssertTrue(app.buttons["exportPhotoPermission"].waitForExistence(timeout: 10))
        XCTAssertTrue(["正在请求…", "打开照片设置", "允许访问照片"].contains(app.buttons["exportPhotoPermission"].label))
        _ = monitor
    }

    func testImportPermissionButtonPresentsSystemPrompt() throws {
        let app = launch(resetPhotos: true)
        app.tabBars.buttons["导入到 iPhone"].tap()
        let allow = app.buttons["importPhotoPermission"]
        XCTAssertTrue(allow.waitForExistence(timeout: 15))
        let monitor = handlePhotoPrompt(app, allow: true)
        allow.tap()
        app.tap()
        XCTAssertTrue(app.staticTexts["正在请求照片权限…"].waitForExistence(timeout: 5) || app.staticTexts["照片权限：全部照片"].waitForExistence(timeout: 10) || app.buttons["importPhotoPermission"].waitForExistence(timeout: 10), "Import permission must respond inside the glass card")
        capture("iPhone-import-photos-system-prompt", app: app)
        _ = monitor
    }
}
