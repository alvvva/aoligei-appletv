import XCTest

/// 用模拟的 Siri 遥控器按键测试浏览器。
/// 触控板滑动（移动光标）没法在界面测试里模拟，那部分由 App 内的 -selftest 自检覆盖。
/// 测试页屏幕中央是一个大链接（光标默认就在那里），点了会打开 example.com，所以需要联网。
final class RemoteControlUITests: XCTestCase {
    private let remote = XCUIRemote.shared
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest"]
        app.launch()
    }

    private var title: XCUIElement { app.staticTexts["titleLabel"] }
    private var status: XCUIElement { app.staticTexts["statusLabel"] }

    private func waitForTitle(_ predicate: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let exp = expectation(for: NSPredicate(format: predicate), evaluatedWith: title)
        let result = XCTWaiter.wait(for: [exp], timeout: timeout)
        XCTAssertEqual(result, .completed, "顶栏标题不满足 \(predicate)", file: file, line: line)
    }

    func testRemoteButtons() {
        waitForTitle("label == '第一页'")

        // 播放/暂停键 = 切换光标模式和滚动模式
        XCTAssertTrue(status.label.hasPrefix("光标模式"), status.label)
        remote.press(.playPause)
        XCTAssertTrue(status.label.hasPrefix("滚动模式"), status.label)
        remote.press(.playPause)
        XCTAssertTrue(status.label.hasPrefix("光标模式"), status.label)

        // 方向键向下 = 向下翻页
        remote.press(.down)
        waitForTitle("label BEGINSWITH '滚动到 ' AND label != '滚动到 0'")
        remote.press(.up)
        waitForTitle("label == '滚动到 0'")

        // 长按触控板 = 打开菜单；返回键关掉菜单
        let menuItem = app.buttons.matching(NSPredicate(format: "label CONTAINS '输入网址或搜索'")).firstMatch
        remote.press(.select, forDuration: 1.2)
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "长按触控板没有打开菜单")
        remote.press(.menu)
        XCTAssertTrue(menuItem.waitForNonExistence(timeout: 5), "返回键没有关掉菜单")
        XCTAssertEqual(app.state, .runningForeground)

        // 按下触控板 = 在光标处点击（光标在屏幕中央的链接上）
        remote.press(.select)
        waitForTitle("label == 'Example Domain'", timeout: 30)

        // 没有可后退的网页时，返回键回到起始页，而不是退出
        remote.press(.menu)
        waitForTitle("label == '起始页'")
        XCTAssertEqual(app.state, .runningForeground, "返回键不应该直接退出 App")

        // 在起始页再按返回键 = 退出到主屏幕
        remote.press(.menu)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.state == .notRunning,
                      "在起始页按返回键应该退出到主屏幕")
    }
}

/// 截宣传图用：打开一个只放了开源动画《大雄兔》的网页，自动用原生播放器全屏播放，再按一下暂停让控制条显示出来，
/// 然后停 20 秒，方便从外面截图。平时跑测试会跳过，设置环境变量 TEST_RUNNER_TVB_SHOWCASE=1 才会执行。
final class ShowcaseUITests: XCTestCase {
    func testPlayerWithControls() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TVB_SHOWCASE"] == "1", "只在截宣传图时运行")
        let page = "data:text/html;charset=utf-8,%3Ctitle%3EBig%20Buck%20Bunny%3C%2Ftitle%3E%3Cbody%20style%3D%22margin%3A0%3Bbackground%3A%23000%22%3E%3Cvideo%20autoplay%20muted%20playsinline%20style%3D%22width%3A1600px%3Bheight%3A900px%22%20src%3D%22https%3A%2F%2Ftest-streams.mux.dev%2Fx36xhzz%2Fx36xhzz.m3u8%22%3E%3C%2Fvideo%3E"
        let app = XCUIApplication()
        app.launchArguments = ["-lastURL", page, "-autoFullscreenVideo", "YES"]
        app.launch()
        sleep(40)
        XCUIRemote.shared.press(.select)
        sleep(20)
    }
}
