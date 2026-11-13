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
        allow.tap()
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Tapping the glass card button must show the real Photos prompt")
        capture("iPhone-export-photos-system-prompt", app: app)
        let deny = alert.buttons.matching(NSPredicate(format: "label IN %@", ["不允许", "Don't Allow", "不允許"])).firstMatch
        XCTAssertTrue(deny.waitForExistence(timeout: 5))
        deny.tap()
        XCTAssertTrue(app.buttons["exportPhotoPermission"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["exportPhotoPermission"].label, "打开照片设置")
        app.buttons["exportPhotoPermission"].tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.buttons["exportPhotoPermission"].waitForExistence(timeout: 10))
    }

    func testImportPermissionButtonPresentsSystemPrompt() throws {
        let app = launch(resetPhotos: true)
        app.tabBars.buttons["导入到 iPhone"].tap()
        let allow = app.buttons["importPhotoPermission"]
        XCTAssertTrue(allow.waitForExistence(timeout: 15))
        allow.tap()
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Import permission must respond inside the glass card")
        capture("iPhone-import-photos-system-prompt", app: app)
        let fullAccess = alert.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] 'full' OR label CONTAINS '完全' OR label CONTAINS '全部' OR label CONTAINS '所有'"
        )).firstMatch
        XCTAssertTrue(fullAccess.waitForExistence(timeout: 5))
        fullAccess.tap()
        XCTAssertTrue(app.staticTexts["照片权限：全部照片"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["importPhotoPermission"].exists)
        app.tabBars.buttons["导出到 Mac"].tap()
        let albumsReady = NSPredicate { _, _ in
            app.staticTexts["没有找到可显示的相册"].exists || app.staticTexts["选择相册"].exists
        }
        let ready = XCTNSPredicateExpectation(predicate: albumsReady, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        XCTAssertFalse(app.buttons["exportPhotoPermission"].exists)
        capture("iPhone-permission-granted-empty-albums", app: app)
    }
}
