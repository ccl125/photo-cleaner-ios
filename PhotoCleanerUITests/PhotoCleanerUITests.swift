import XCTest

/// 真机全链路 UI 测试：启动（-autoTest 自测模式）→ 相册权限弹窗 → 小范围扫描 200 张
/// → 自动进分析页 → 等待分组结果 → 截图留档。
///
/// App 侧自测逻辑见 PhotoCleanerApp.runAutoTest()，关键节点日志前缀 [AutoTest]。
final class PhotoCleanerUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-autoTest"]

        // 相册权限系统弹窗（中英文按钮文案都兜底）
        addUIInterruptionMonitor(withDescription: "照片权限弹窗") { alert in
            let candidates = [
                "允许访问所有照片", "允许访问全部照片", "允许完全访问",
                "Allow Full Access", "Allow Access to All Photos",
                "允许", "Allow", "OK",
            ]
            for label in candidates where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testFullFlow() throws {
        app.launch()
        print("[UITest] App 已启动（-autoTest）")

        // 权限弹窗处理：interruption monitor 需要一次 UI 交互才会派发；
        // 同时直接查 app.alerts 兜底（较新 iOS 上权限弹窗对 App 进程可见）
        handlePhotoPermissionAlert()

        // 阶段 1：等待扫描完成或已进分析页（autoTest 会自动跑 200 张并自动跳转）
        // 兜底：若自测模式没触发，手动点"小范围测试"按钮
        let testScan = app.buttons["testScanButton"]
        let analyzeLink = app.buttons["analyzeLink"]
        if waitForExistence(testScan, timeout: 20), testScan.isEnabled {
            print("[UITest] 兜底：手动点小范围测试按钮")
            testScan.tap()
        }

        // 阶段 2：等待分析结果出现（重复/相似 section 头 或 空态文案），最长 10 分钟轮询
        let deadline = Date().addingTimeInterval(600)
        var sawResults = false
        var sawEmpty = false
        while Date() < deadline {
            handlePhotoPermissionAlert()  // 弹窗可能延迟出现
            if app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "重复照片 ·")).firstMatch.exists {
                sawResults = true
                break
            }
            if app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "相似照片（同主题")).firstMatch.exists {
                sawResults = true
                break
            }
            if app.staticTexts["没有发现相似照片"].exists {
                sawEmpty = true
                break
            }
            // 扫描完成后首屏出现"分析相似照片"入口而尚未自动跳转时，手动点进去
            if analyzeLink.waitForExistence(timeout: 0), analyzeLink.isHittable {
                print("[UITest] 兜底：手动点进分析页")
                analyzeLink.tap()
            }
            Thread.sleep(forTimeInterval: 5)
        }
        XCTAssertTrue(sawResults || sawEmpty,
                      "10 分钟内未出现分组结果（sawResults=\(sawResults), sawEmpty=\(sawEmpty)）")

        // 收集结果信息进测试日志
        let statusText = app.staticTexts["autoTestStatus"]
        if statusText.waitForExistence(timeout: 5) {
            print("[UITest] AutoTest 状态: \(statusText.label)")
        }
        if sawResults {
            let dupHeaders = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "重复照片 ·"))
            let simHeaders = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "相似照片（同主题"))
            if let h = dupHeaders.firstMatch.value as? String { print("[UITest] \(h)") }
            if simHeaders.count > 0, let h = simHeaders.firstMatch.value as? String { print("[UITest] \(h)") }
            print("[UITest] 分组结果已出现")
        } else {
            print("[UITest] 空态：没有发现相似照片")
        }

        // 截图留档
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.lifetime = .keepAlways
        attachment.name = "分析结果页"
        add(attachment)
        print("[UITest] 截图已附加")
    }

    // MARK: - 权限弹窗

    /// 双通道处理系统权限弹窗：app.alerts 直查 + 触发 interruption monitor 派发。
    private func handlePhotoPermissionAlert() {
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 0) {
            let candidates = [
                "允许访问所有照片", "允许访问全部照片", "允许完全访问",
                "Allow Full Access", "Allow Access to All Photos",
                "允许", "Allow", "OK",
            ]
            for label in candidates where alert.buttons[label].exists {
                print("[UITest] 处理权限弹窗：点「\(label)」")
                alert.buttons[label].tap()
                return
            }
        }
        // 触发 interruption monitor 派发（有弹窗时任何 UI 交互都会先走 monitor）
        if app.alerts.count > 0 {
            app.tap()
        }
    }

    private func waitForExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        element.waitForExistence(timeout: timeout)
    }
}
