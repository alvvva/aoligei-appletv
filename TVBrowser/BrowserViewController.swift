import AVKit
import UIKit

private enum UserAgent {
    static let desktop = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
    static let mobile = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
}

/// 保证回调恰好调用一次。WebKit 要求网页弹框的回调必须被调用，
/// 否则会直接让 App 闪退；弹框被关掉却没点按钮时，这里会在释放时用 fallback 补调一次。
private final class CallOnce<T> {
    private var callback: ((T) -> Void)?
    private let fallback: T

    init(fallback: T, _ callback: @escaping (T) -> Void) {
        self.fallback = fallback
        self.callback = callback
    }

    func call(_ value: T) {
        let cb = callback
        callback = nil
        cb?(value)
    }

    deinit {
        callback?(fallback)
    }
}

/// 网页里注入的视频脚本发来的汇报（每个框架一份）。
private struct FrameReport: Decodable {
    struct Mac: Decodable {
        let url: String
        let next: String
        let prev: String
    }
    struct Video: Decodable {
        let src: String
        let t: Double
        let d: Double
        let paused: Bool
        let w: Int
        let h: Int
    }
    let top: Bool
    let href: String
    let title: String?
    let mac: Mac?
    let next: String?
    let video: Video?
}

/// 点击网页后脚本返回的结果。
private struct ClickResult: Decodable {
    let kind: String
    let value: String?
    let label: String?
    let secure: Bool?
    let multiline: Bool?
    let inputType: String?
    let options: [String]?
    let selected: Int?
}

final class BrowserViewController: UIViewController {
    private enum Mode { case cursor, scroll }

    private static let topBarHeight: CGFloat = 100
    private static let scrollFactor: CGFloat = 2.2

    private let store = Store.shared
    private var webView: TBWebView?

    private let topBar = UIView()
    private let titleLabel = UILabel()
    private let urlLabel = UILabel()
    private let statusLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let cursorView = UIImageView(image: Cursor.makeImage())
    private let toast = ToastView()

    private var mode: Mode = .cursor
    private var cursorPoint = CGPoint(x: 960, y: 540)
    private var lastPanTranslation = CGPoint.zero
    private var momentum = CGPoint.zero
    private var momentumLink: CADisplayLink?
    private var menuPressHandledByBack = false
    private var didAppearOnce = false
    /// 页面加载完成时调用一次（自检用）。
    private var onFinishLoad: (() -> Void)?
    private var isSelfTest: Bool { ProcessInfo.processInfo.arguments.contains("-selftest") }
    private var isUITest: Bool { ProcessInfo.processInfo.arguments.contains("-uitest") }

    // 视频播放
    private var frameReports: [String: FrameReport] = [:]
    private var topReport: FrameReport?
    private var nativePlayer: NativeVideoPlayer?
    private var webFullscreen = false
    private var hintedVideoPages = Set<String>()
    private var autoPlayedPages = Set<String>()
    private var autoPlayNextUntil: Date?
    private var fullscreenSwipe: CGFloat = 0
    private var blockedPopups = 0
    /// 为换手机版重新打开过的直播间地址，避免反复重开
    private var mobileReloadURL: URL?
    /// 最近一次原生播放失败的原因（自检用）。
    private var lastPlaybackFailure: String?
    private var zoomedSite: String?? = .none

    // MARK: - 生命周期

    override func loadView() {
        let root = RemoteInputView()
        root.backgroundColor = .black
        view = root
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [view] }

    override func viewDidLoad() {
        super.viewDidLoad()
        setUpWebView()
        setUpTopBar()
        view.addSubview(cursorView)
        view.addSubview(toast)
        setUpRemoteGestures()
        updateTopBar()
        loadInitialPage()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didAppearOnce else { return }
        didAppearOnce = true
        if webView == nil {
            showWebKitMissing()
        } else if isSelfTest {
            #if DEBUG
            Task { await runSelfTest() }
            #endif
        } else if !store.hasSeenHelp && !isUITest {
            store.hasSeenHelp = true
            showHelp()
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // tvOS 给屏幕四周留了安全区（照顾老电视的过扫描），网页视图会因此左右各缩进约 80 点，
        // 既浪费空间，又让光标坐标和网页坐标对不上。这里把安全区抵消掉，让网页铺满屏幕。
        let base = view.window?.safeAreaInsets ?? .zero
        let wanted = UIEdgeInsets(top: -base.top, left: -base.left, bottom: -base.bottom, right: -base.right)
        if additionalSafeAreaInsets != wanted {
            additionalSafeAreaInsets = wanted
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let b = view.bounds
        let showBar = store.showTopBar && !webFullscreen
        let barHeight = showBar ? Self.topBarHeight : 0
        topBar.isHidden = !showBar
        topBar.frame = CGRect(x: 0, y: 0, width: b.width, height: Self.topBarHeight)
        let side: CGFloat = 80
        let statusWidth: CGFloat = 420
        titleLabel.frame = CGRect(x: side, y: 12, width: b.width - side * 2 - statusWidth - 20, height: 42)
        urlLabel.frame = CGRect(x: side, y: 54, width: b.width - side * 2 - statusWidth - 20, height: 34)
        statusLabel.frame = CGRect(x: b.width - side - statusWidth, y: 30, width: statusWidth, height: 40)
        progressView.frame = CGRect(x: 0, y: Self.topBarHeight - 6, width: b.width, height: 6)
        webView?.frame = CGRect(x: 0, y: barHeight, width: b.width, height: b.height - barHeight)
        placeCursor()
    }

    // MARK: - 界面搭建

    private func setUpWebView() {
        guard TBWebView.isWebKitAvailable() else { return }
        let wv = TBWebView(frame: view.bounds)
        wv.delegate = self
        wv.customUserAgent = store.desktopMode ? UserAgent.desktop : UserAgent.mobile
        wv.pageZoom = CGFloat(store.pageZoom)
        installPageScripts(on: wv)
        view.addSubview(wv)
        webView = wv
    }

    /// 注入去广告脚本和视频脚本（对之后加载的页面生效）。
    private func installPageScripts(on wv: TBWebView) {
        wv.removeAllUserScripts()
        if store.adBlockEnabled, let source = Self.bundledScript("adblock") {
            wv.addUserScript(source, atDocumentStart: true, mainFrameOnly: false)
        }
        if let source = Self.bundledScript("video") {
            wv.addUserScript(source, atDocumentStart: true, mainFrameOnly: false)
        }
        wv.blockPopups = store.adBlockEnabled
    }

    private static func bundledScript(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func setUpTopBar() {
        topBar.backgroundColor = UIColor(red: 0.09, green: 0.1, blue: 0.13, alpha: 1)
        titleLabel.accessibilityIdentifier = "titleLabel"
        statusLabel.accessibilityIdentifier = "statusLabel"
        titleLabel.font = .systemFont(ofSize: 32, weight: .semibold)
        titleLabel.textColor = .white
        urlLabel.font = .systemFont(ofSize: 24)
        urlLabel.textColor = UIColor(white: 0.65, alpha: 1)
        urlLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: 24, weight: .medium)
        statusLabel.textColor = UIColor(white: 0.75, alpha: 1)
        statusLabel.textAlignment = .right
        progressView.progressTintColor = UIColor(red: 0.33, green: 0.61, blue: 0.96, alpha: 1)
        progressView.trackTintColor = .clear
        [titleLabel, urlLabel, statusLabel, progressView].forEach(topBar.addSubview)
        view.addSubview(topBar)
    }

    private func setUpRemoteGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.delegate = self
        view.addGestureRecognizer(pan)

        let longSelect = UILongPressGestureRecognizer(target: self, action: #selector(handleLongSelect(_:)))
        longSelect.minimumPressDuration = 0.6
        addPressRecognizer(longSelect, types: [.select])

        let tapSelect = addPressRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleSelect)), types: [.select])
        tapSelect.require(toFail: longSelect)

        addPressRecognizer(UITapGestureRecognizer(target: self, action: #selector(handlePlayPause)), types: [.playPause])
        addPressRecognizer(UITapGestureRecognizer(target: self, action: #selector(pageUp)), types: [.upArrow])
        addPressRecognizer(UITapGestureRecognizer(target: self, action: #selector(pageDown)), types: [.downArrow])
        addPressRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleLeft)), types: [.leftArrow])
        addPressRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleRight)), types: [.rightArrow])
    }

    @discardableResult
    private func addPressRecognizer<T: UIGestureRecognizer>(_ recognizer: T, types: [UIPress.PressType]) -> T {
        recognizer.allowedPressTypes = types.map { NSNumber(value: $0.rawValue) }
        recognizer.allowedTouchTypes = []
        recognizer.delegate = self
        view.addGestureRecognizer(recognizer)
        return recognizer
    }

    // MARK: - 页面加载

    private var isOnStartPage: Bool {
        guard let url = webView?.url else { return true }
        return url.absoluteString == "about:blank"
    }

    private func loadInitialPage() {
        if isSelfTest { return }
        #if DEBUG
        if isUITest {
            webView?.loadHTMLString(Self.uiTestPage, baseURL: URL(string: "https://uitest.local/"))
            return
        }
        #endif
        if let last = store.lastURL, let url = URL(string: last) {
            webView?.loadURL(url)
        } else {
            goHome()
        }
    }

    private func goHome() {
        if !store.homepage.isEmpty, let url = URL(string: store.homepage) {
            webView?.loadURL(url)
        } else {
            showStartPage()
        }
    }

    private func showStartPage() {
        store.lastURL = nil
        webView?.loadHTMLString(StartPage.html(bookmarks: store.bookmarks, recent: store.history,
                                               engineName: store.searchEngine.displayName), baseURL: nil)
    }

    private func refreshStartPageIfVisible() {
        if isOnStartPage { showStartPage() }
    }

    private func open(_ text: String) {
        guard let url = URLInput.url(for: text, engine: store.searchEngine) else { return }
        webView?.loadURL(url)
    }

    private var currentPageURLString: String? {
        guard !isOnStartPage, let url = webView?.url, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url.absoluteString
    }

    private func updateTopBar() {
        guard let wv = webView else {
            titleLabel.text = "奥利给"
            urlLabel.text = "找不到网页引擎"
            return
        }
        if isOnStartPage {
            titleLabel.text = "起始页"
            urlLabel.text = "把光标移到这里按一下，可以输入网址或搜索"
        } else {
            let title = wv.title ?? ""
            titleLabel.text = title.isEmpty ? (wv.isLoading ? "正在加载…" : (wv.url?.host ?? "")) : title
            urlLabel.text = wv.url?.absoluteString ?? ""
        }
        progressView.isHidden = !wv.isLoading
        progressView.setProgress(Float(wv.estimatedProgress), animated: true)
        let modeText = mode == .cursor ? "光标模式" : "滚动模式"
        statusLabel.text = "\(modeText) · \(store.desktopMode ? "电脑版" : "手机版")"
    }

    // MARK: - 光标与滚动

    private func placeCursor() {
        let b = view.bounds
        cursorPoint.x = min(max(cursorPoint.x, 0), b.width - 4)
        cursorPoint.y = min(max(cursorPoint.y, 0), b.height - 4)
        cursorView.frame.origin = CGPoint(x: cursorPoint.x - Cursor.hotspot.x, y: cursorPoint.y - Cursor.hotspot.y)
        view.bringSubviewToFront(cursorView)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        if webFullscreen {
            handleFullscreenSwipe(gesture, translation: translation)
            return
        }
        switch gesture.state {
        case .began:
            stopMomentum()
            lastPanTranslation = .zero
            fallthrough
        case .changed:
            let delta = CGPoint(x: translation.x - lastPanTranslation.x, y: translation.y - lastPanTranslation.y)
            lastPanTranslation = translation
            if mode == .cursor {
                moveCursor(by: delta)
            } else {
                scroll(dx: -delta.x * Self.scrollFactor, dy: -delta.y * Self.scrollFactor)
            }
        case .ended:
            if mode == .scroll {
                let v = gesture.velocity(in: view)
                startMomentum(CGPoint(x: -v.x * Self.scrollFactor * 0.5, y: -v.y * Self.scrollFactor * 0.5))
            }
        default:
            break
        }
    }

    /// 光标移动的放大倍数：慢慢滑时倍数小，方便精确对准；快速滑时倍数大，一下就能划过屏幕。
    static func cursorGain(forDelta magnitude: CGFloat, speed: CGFloat) -> CGFloat {
        let acceleration = min(1.6, 0.3 + magnitude / 28)
        return speed * acceleration
    }

    private func moveCursor(by delta: CGPoint) {
        let magnitude = hypot(delta.x, delta.y)
        guard magnitude > 0.25 else { return } // 忽略手指按压时的细微抖动
        let gain = Self.cursorGain(forDelta: magnitude, speed: CGFloat(store.cursorSpeed))
        let b = view.bounds
        let target = CGPoint(x: cursorPoint.x + delta.x * gain, y: cursorPoint.y + delta.y * gain)

        // 光标顶到屏幕边缘时，继续往外推就滚动页面
        var overflow = CGPoint.zero
        if target.y < 0 { overflow.y = target.y }
        if target.y > b.height - 4 { overflow.y = target.y - (b.height - 4) }
        if target.x < 0 { overflow.x = target.x }
        if target.x > b.width - 4 { overflow.x = target.x - (b.width - 4) }

        cursorPoint = target
        placeCursor()
        if overflow != .zero {
            scroll(dx: overflow.x * 2, dy: overflow.y * 2)
        }
    }

    /// 先滚动整页；整页滚不动时，滚动光标下的内部区域。
    @discardableResult
    private func scroll(dx: CGFloat, dy: CGFloat, animated: Bool = false) -> Bool {
        guard let wv = webView else { return false }
        if let sv = wv.scrollView {
            let inset = sv.adjustedContentInset
            let minX = -inset.left, minY = -inset.top
            let maxX = max(minX, sv.contentSize.width - sv.bounds.width + inset.right)
            let maxY = max(minY, sv.contentSize.height - sv.bounds.height + inset.bottom)
            let current = sv.contentOffset
            let next = CGPoint(x: min(max(current.x + dx, minX), maxX), y: min(max(current.y + dy, minY), maxY))
            if abs(next.x - current.x) > 0.5 || abs(next.y - current.y) > 0.5 {
                sv.setContentOffset(next, animated: animated)
                return true
            }
        }
        let p = view.convert(cursorPoint, to: wv)
        wv.evaluateJavaScript(PageScripts.scrollInner(x: p.x, y: max(p.y, 1), viewWidth: wv.bounds.width, dx: dx, dy: dy), completion: nil)
        return false
    }

    private func startMomentum(_ velocity: CGPoint) {
        guard abs(velocity.x) > 60 || abs(velocity.y) > 60 else { return }
        momentum = velocity
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        let dt = CGFloat(max(link.targetTimestamp - link.timestamp, 1.0 / 120))
        let moved = scroll(dx: momentum.x * dt, dy: momentum.y * dt)
        let decay = pow(0.93, dt * 60)
        momentum = CGPoint(x: momentum.x * decay, y: momentum.y * decay)
        if !moved || (abs(momentum.x) < 30 && abs(momentum.y) < 30) {
            stopMomentum()
        }
    }

    private func stopMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
        momentum = .zero
    }

    @objc private func pageUp() {
        if webFullscreen { showVideoOptions(); return }
        scroll(dx: 0, dy: -(webView?.bounds.height ?? 800) * 0.8, animated: true)
    }

    @objc private func pageDown() {
        if webFullscreen { return }
        scroll(dx: 0, dy: (webView?.bounds.height ?? 800) * 0.8, animated: true)
    }

    @objc private func handleLeft() {
        if webFullscreen { seekWebVideo(by: -10); return }
        scroll(dx: -(webView?.bounds.width ?? 1200) * 0.4, dy: 0, animated: true)
    }

    @objc private func handleRight() {
        if webFullscreen { seekWebVideo(by: 10); return }
        scroll(dx: (webView?.bounds.width ?? 1200) * 0.4, dy: 0, animated: true)
    }

    /// 播放/暂停键：网页里有视频就全屏播放，否则切换光标/滚动模式。
    @objc private func handlePlayPause() {
        if webFullscreen {
            sendVideoCommand(["cmd": "toggle"])
            return
        }
        if hasVideo {
            playVideoFullscreen()
        } else {
            setMode(mode == .cursor ? .scroll : .cursor)
        }
    }

    @objc private func toggleMode() {
        setMode(mode == .cursor ? .scroll : .cursor)
    }

    private func setMode(_ newMode: Mode) {
        mode = newMode
        stopMomentum()
        UIView.animate(withDuration: 0.15) { self.cursorView.alpha = newMode == .cursor ? 1 : 0 }
        updateTopBar()
        showToast(newMode == .cursor
                  ? "光标模式：滑动移动光标，按下点击"
                  : "滚动模式：滑动滚动页面，按播放/暂停键回到光标模式")
    }

    // MARK: - 点击

    @objc private func handleSelect() {
        debugLog("select tap")
        if webFullscreen {
            sendVideoCommand(["cmd": "toggle"])
            return
        }
        if mode == .scroll {
            setMode(.cursor)
            return
        }
        pulseCursor()
        if store.showTopBar && cursorPoint.y < Self.topBarHeight {
            showAddressInput()
            return
        }
        clickAtCursor { [weak self] info in
            if let info { self?.handleClickResult(info) }
        }
    }

    /// 在光标位置点击网页，把脚本返回的结果交给 completion（主线程）。
    private func clickAtCursor(completion: @escaping (ClickResult?) -> Void) {
        guard let wv = webView else { completion(nil); return }
        let p = view.convert(cursorPoint, to: wv)
        let script = PageScripts.click(x: p.x, y: p.y, viewWidth: wv.bounds.width)
        wv.evaluateJavaScript(script) { result, _ in
            let info = (result as? String)?.data(using: .utf8).flatMap { try? JSONDecoder().decode(ClickResult.self, from: $0) }
            DispatchQueue.main.async { completion(info) }
        }
    }

    private func handleClickResult(_ info: ClickResult) {
        switch info.kind {
        case "text": showTextInput(info)
        case "select": showSelectOptions(info)
        default: break
        }
    }

    private func pulseCursor() {
        UIView.animate(withDuration: 0.08, animations: {
            self.cursorView.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        }, completion: { _ in
            UIView.animate(withDuration: 0.12) { self.cursorView.transform = .identity }
        })
    }

    @objc private func handleLongSelect(_ gesture: UILongPressGestureRecognizer) {
        debugLog("long select state=\(gesture.state.rawValue)")
        guard gesture.state == .began else { return }
        if webFullscreen { showVideoOptions() } else { showMenu() }
    }

    // MARK: - 返回键

    /// 返回键能不能留在 App 里处理：有可后退的网页，或者当前不在起始页（可以回到起始页）。
    /// 只有已经在起始页时，返回键才交给系统退出 App。
    private var backPressStaysInApp: Bool {
        guard let wv = webView else { return false }
        return wv.canGoBack || !isOnStartPage
    }

    /// 后退；没有可后退的网页时回到起始页。
    /// （从起始页这类本地生成的页面点进网站后，WebKit 不保留起始页的后退记录，所以需要这一步。）
    private func goBackOrToStartPage() {
        if webView?.canGoBack == true {
            webView?.goBack()
        } else {
            showStartPage()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }), presentedViewController == nil, webFullscreen || backPressStaysInApp {
            menuPressHandledByBack = true
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }), menuPressHandledByBack {
            menuPressHandledByBack = false
            if webFullscreen { exitWebFullscreen() } else { goBackOrToStartPage() }
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }), menuPressHandledByBack {
            menuPressHandledByBack = false
            return
        }
        super.pressesCancelled(presses, with: event)
    }

    // MARK: - 输入

    private func showAddressInput() {
        let alert = UIAlertController(title: "输入网址或搜索",
                                      message: "直接输入网址（如 bilibili.com），或输入要用 \(store.searchEngine.displayName) 搜索的内容。",
                                      preferredStyle: .alert)
        alert.addTextField { [weak self] field in
            field.text = self?.currentPageURLString
            field.placeholder = "网址或搜索词"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "前往", style: .default) { [weak self, weak alert] _ in
            self?.open(alert?.textFields?.first?.text ?? "")
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        presentSafely(alert)
    }

    private func showTextInput(_ info: ClickResult) {
        let title = (info.label?.isEmpty == false) ? info.label! : "输入文字"
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = info.value
            field.isSecureTextEntry = info.secure ?? false
            field.autocapitalizationType = .none
            switch info.inputType ?? "" {
            case "email": field.keyboardType = .emailAddress
            case "url": field.keyboardType = .URL
            case "number", "tel": field.keyboardType = .numbersAndPunctuation
            default: field.keyboardType = .default
            }
        }
        alert.addAction(UIAlertAction(title: "完成并提交", style: .default) { [weak self, weak alert] _ in
            self?.webView?.evaluateJavaScript(PageScripts.setText(alert?.textFields?.first?.text ?? "", submit: true), completion: nil)
        })
        alert.addAction(UIAlertAction(title: "只填入，不提交", style: .default) { [weak self, weak alert] _ in
            self?.webView?.evaluateJavaScript(PageScripts.setText(alert?.textFields?.first?.text ?? "", submit: false), completion: nil)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        presentSafely(alert)
    }

    private func showSelectOptions(_ info: ClickResult) {
        let options = info.options ?? []
        guard !options.isEmpty else { return }
        let sheet = UIAlertController(title: (info.label?.isEmpty == false) ? info.label : "请选择", message: nil, preferredStyle: .actionSheet)
        for (index, option) in options.enumerated() {
            let mark = index == info.selected ? "✓ " : ""
            sheet.addAction(UIAlertAction(title: mark + (option.isEmpty ? "（空）" : option), style: .default) { [weak self] _ in
                self?.webView?.evaluateJavaScript(PageScripts.selectOption(index), completion: nil)
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        presentSafely(sheet)
    }

    // MARK: - 菜单

    private func showMenu() {
        debugLog("show menu presented=\(String(describing: presentedViewController))")
        guard let wv = webView else { showWebKitMissing(); return }
        var actions: [(String, () -> Void)] = []
        if hasVideo {
            actions.append(("▶️  全屏播放视频", { [weak self] in self?.playVideoFullscreen() }))
            actions.append(("🔲  网页内全屏播放", { [weak self] in self?.enterWebFullscreen() }))
        }
        actions.append(("🔍  输入网址或搜索", { [weak self] in self?.showAddressInput() }))
        actions.append(("🏠  主页", { [weak self] in self?.goHome() }))
        if wv.isLoading {
            actions.append(("✕  停止加载", { [weak self] in self?.webView?.stopLoading() }))
        } else {
            actions.append(("↻  刷新", { [weak self] in self?.reloadPage() }))
        }
        if wv.canGoBack || !isOnStartPage { actions.append(("←  后退", { [weak self] in self?.goBackOrToStartPage() })) }
        if wv.canGoForward { actions.append(("→  前进", { [weak self] in self?.webView?.goForward() })) }
        if let url = currentPageURLString {
            if store.isBookmarked(url) {
                actions.append(("☆  取消收藏本页", { [weak self] in
                    self?.store.removeBookmark(url: url)
                    self?.showToast("已取消收藏")
                }))
            } else {
                actions.append(("★  收藏本页", { [weak self] in self?.bookmarkCurrentPage() }))
            }
        }
        actions.append(("📚  收藏夹", { [weak self] in self?.showBookmarks() }))
        actions.append(("🕘  历史记录", { [weak self] in self?.showHistory() }))
        actions.append(("🔠  页面缩放（\(isOnStartPage ? "当前" : "本站") \(Int((currentZoom * 100).rounded()))%）", { [weak self] in self?.showZoomMenu() }))
        actions.append((mode == .cursor ? "↕️  切换到滚动模式" : "🖱  切换到光标模式", { [weak self] in
            guard let self else { return }
            self.setMode(self.mode == .cursor ? .scroll : .cursor)
        }))
        actions.append((store.desktopMode ? "📱  切换为手机版网页" : "🖥  切换为电脑版网页", { [weak self] in self?.toggleDesktopMode() }))
        actions.append(("⚙️  设置", { [weak self] in self?.showSettings() }))
        actions.append(("❓  遥控器操作说明", { [weak self] in self?.showHelp() }))
        showSheet(title: "菜单", message: wv.title, actions: actions)
    }

    private func reloadPage() {
        if isOnStartPage { showStartPage() } else { webView?.reload() }
    }

    private func bookmarkCurrentPage() {
        guard let url = currentPageURLString else { return }
        let title = webView?.title ?? ""
        if store.addBookmark(title: title, url: url) {
            showToast("已收藏：\(title.isEmpty ? url : title)")
        } else {
            showToast("这个网页已经在收藏夹里了")
        }
    }

    private func showBookmarks() {
        let items = store.bookmarks
        guard !items.isEmpty else {
            showToast("收藏夹是空的。打开网页后长按触控板，选择「收藏本页」。")
            return
        }
        var actions: [(String, () -> Void)] = items.map { item in
            (item.title, { [weak self] in
                if let url = URL(string: item.url) { self?.webView?.loadURL(url) }
            })
        }
        actions.append(("🗑  删除收藏…", { [weak self] in self?.showDeleteBookmarks() }))
        showSheet(title: "收藏夹", actions: actions)
    }

    private func showDeleteBookmarks() {
        let actions: [(String, () -> Void)] = store.bookmarks.map { item in
            ("删除「\(item.title)」", { [weak self] in
                self?.store.removeBookmark(url: item.url)
                self?.showToast("已删除「\(item.title)」")
                self?.refreshStartPageIfVisible()
            })
        }
        showSheet(title: "选择要删除的收藏", actions: actions)
    }

    private func confirmClearHistory() {
        let alert = UIAlertController(title: "清空历史记录？", message: "起始页的「最近看过」和全部历史都会删除，收藏不受影响。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
            self?.store.clearHistory()
            self?.refreshStartPageIfVisible()
            self?.showToast("历史记录已清空")
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        presentSafely(alert)
    }

    private func showHistory() {
        let items = store.history.prefix(60)
        guard !items.isEmpty else {
            showToast("还没有历史记录")
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        var actions: [(String, () -> Void)] = items.map { item in
            ("\(item.title)  ·  \(formatter.string(from: item.date))", { [weak self] in
                if let url = URL(string: item.url) { self?.webView?.loadURL(url) }
            })
        }
        actions.append(("🗑  清空历史记录", { [weak self] in
            self?.store.clearHistory()
            self?.showToast("历史记录已清空")
        }))
        showSheet(title: "历史记录", actions: actions)
    }

    private func showZoomMenu() {
        let levels: [Double] = [0.5, 0.67, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
        let actions: [(String, () -> Void)] = levels.map { level in
            let mark = abs(level - currentZoom) < 0.001 ? "✓ " : ""
            return ("\(mark)\(Int((level * 100).rounded()))%", { [weak self] in
                guard let self else { return }
                let host = self.isOnStartPage ? nil : self.webView?.url?.host
                self.store.setZoom(level, forHost: host)
                self.webView?.pageZoom = CGFloat(level)
            })
        }
        let site = isOnStartPage ? nil : Store.siteKey(webView?.url?.host)
        let note = "放大后页面会超出屏幕，可以用遥控器左右键或把光标推到边缘来滚动。"
        showSheet(title: "页面缩放", message: site.map { "只对 \($0) 生效，会记住。\(note)" } ?? note, actions: actions)
    }

    private func toggleDesktopMode() {
        store.desktopMode.toggle()
        webView?.customUserAgent = store.desktopMode ? UserAgent.desktop : UserAgent.mobile
        updateTopBar()
        reloadPage()
        showToast(store.desktopMode ? "已切换为电脑版网页" : "已切换为手机版网页")
    }

    private func showSettings() {
        var actions: [(String, () -> Void)] = []
        actions.append(("搜索引擎：\(store.searchEngine.displayName)", { [weak self] in self?.showSearchEngines() }))
        let speedName = Store.cursorSpeeds.min(by: { abs($0.value - store.cursorSpeed) < abs($1.value - store.cursorSpeed) })?.name ?? "中"
        actions.append(("光标速度：\(speedName)", { [weak self] in self?.showCursorSpeeds() }))
        actions.append(("去广告：\(store.adBlockEnabled ? "开" : "关")", { [weak self] in
            guard let self, let wv = self.webView else { return }
            self.store.adBlockEnabled.toggle()
            self.installPageScripts(on: wv)
            self.reloadPage()
            self.showToast(self.store.adBlockEnabled ? "去广告已打开" : "去广告已关闭")
        }))
        actions.append(("网页视频开始播放时自动全屏：\(store.autoFullscreen ? "开" : "关")", { [weak self] in
            guard let self else { return }
            self.store.autoFullscreen.toggle()
            self.showToast(self.store.autoFullscreen ? "视频开始播放时会自动全屏" : "已关闭自动全屏，按 ⏯ 播放/暂停键手动全屏")
        }))
        if let url = currentPageURLString {
            actions.append(("把当前网页设为主页", { [weak self] in
                self?.store.homepage = url
                self?.showToast("主页已设为当前网页")
            }))
        }
        if !store.homepage.isEmpty {
            actions.append(("主页恢复为起始页", { [weak self] in
                self?.store.homepage = ""
                self?.showToast("主页已恢复为起始页")
            }))
        }
        actions.append((store.showTopBar ? "隐藏顶部地址栏（全屏看网页）" : "显示顶部地址栏", { [weak self] in
            guard let self else { return }
            self.store.showTopBar.toggle()
            self.view.setNeedsLayout()
        }))
        actions.append(("清除缓存和 Cookie（会退出各网站的登录）", { [weak self] in
            TBWebView.clearAllWebsiteData { self?.showToast("缓存和 Cookie 已清除") }
        }))
        showSheet(title: "设置", actions: actions)
    }

    private func showSearchEngines() {
        let actions: [(String, () -> Void)] = SearchEngine.allCases.map { engine in
            ((engine == store.searchEngine ? "✓ " : "") + engine.displayName, { [weak self] in
                self?.store.searchEngine = engine
                self?.refreshStartPageIfVisible()
            })
        }
        showSheet(title: "搜索引擎", actions: actions)
    }

    private func showCursorSpeeds() {
        let actions: [(String, () -> Void)] = Store.cursorSpeeds.map { name, value in
            ((abs(value - store.cursorSpeed) < 0.01 ? "✓ " : "") + name, { [weak self] in self?.store.cursorSpeed = value })
        }
        showSheet(title: "光标速度", actions: actions)
    }

    private func showHelp() {
        let text = """
        • 在触控板上滑动：移动光标
        • 按下触控板：点击（点到输入框会弹出键盘）
        • 长按触控板：打开菜单（收藏、历史、缩放、设置）
        • 播放/暂停键：网页里有视频时全屏播放；没有视频时切换「光标 / 滚动模式」
        • 全屏播放时：按下触控板暂停，左右滑动拖进度，向下滑可调倍速，返回键退出
        • 光标推到屏幕上下边缘：自动滚动页面
        • 遥控器外圈的上/下：向上/向下翻页
        • 返回键（‹ 或 MENU）：后退；无法后退时退出
        • 把光标移到顶部地址栏按一下：输入网址
        """
        let alert = UIAlertController(title: "遥控器操作说明", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        presentSafely(alert)
    }

    private func showWebKitMissing() {
        let alert = UIAlertController(title: "无法显示网页",
                                      message: "这台 Apple TV 的系统里找不到网页引擎（WebKit）。请把 Apple TV 升级到最新的 tvOS 后再试。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        presentSafely(alert)
    }

    // MARK: - 小工具

    private func showSheet(title: String?, message: String? = nil, actions: [(String, () -> Void)]) {
        let sheet = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
        for (name, handler) in actions {
            sheet.addAction(UIAlertAction(title: name, style: .default) { _ in handler() })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        presentSafely(sheet)
    }

    private func presentSafely(_ controller: UIViewController) {
        if let presented = presentedViewController {
            presented.dismiss(animated: false) { [weak self] in self?.present(controller, animated: true) }
        } else {
            present(controller, animated: true)
        }
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        NSLog("TVB %@", message)
        #endif
    }

    private func showToast(_ text: String, duration: TimeInterval = 2.5) {
        toast.show(text, in: view.bounds, duration: duration)
    }
}

// MARK: - 视频播放

extension BrowserViewController {
    /// 页面上最主要的视频：正在播放的优先，其次是画面最大的。
    private var currentVideo: FrameReport.Video? {
        frameReports.values.compactMap(\.video).max { a, b in
            let sa = Double(a.w * a.h) + (a.paused ? 0 : 1e9)
            let sb = Double(b.w * b.h) + (b.paused ? 0 : 1e9)
            return sa < sb
        }
    }

    /// 可以交给原生播放器的视频地址：MacCMS 网站（欧乐等）用 player_aaaa 里的地址，其他网站用视频脚本找到的地址。
    private var mediaURL: URL? {
        if let mac = topReport?.mac?.url, !mac.isEmpty, let url = URL(string: mac) { return url }
        if let src = currentVideo?.src, !src.isEmpty, let url = URL(string: src) { return url }
        return nil
    }

    private var nextEpisodeURL: URL? {
        guard let next = topReport?.next, !next.isEmpty else { return nil }
        return URL(string: next)
    }

    private var hasVideo: Bool { currentVideo != nil || mediaURL != nil }

    private var videoTitle: String {
        let raw = topReport?.title ?? webView?.title ?? ""
        let short = raw.components(separatedBy: " - ").first ?? raw
        return short.trimmingCharacters(in: .whitespaces).isEmpty ? "网页视频" : short
    }

    private var currentZoom: Double {
        store.zoom(forHost: isOnStartPage ? nil : webView?.url?.host)
    }

    /// 换了网站就套用这个网站的缩放比例。
    private func applySiteZoomIfNeeded() {
        guard let wv = webView else { return }
        let site = isOnStartPage ? nil : Store.siteKey(wv.url?.host)
        if case .some(let applied) = zoomedSite, applied == site { return }
        zoomedSite = .some(site)
        let zoom = CGFloat(store.zoom(forHost: site))
        if abs(wv.pageZoom - zoom) > 0.001 { wv.pageZoom = zoom }
    }

    /// 把指令发给页面和所有内嵌框架里的视频脚本。
    private func sendVideoCommand(_ command: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: command),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__tvbCommand && window.__tvbCommand(\(json))", completion: nil)
    }

    private func seekWebVideo(by seconds: Double) {
        sendVideoCommand(["cmd": "seekBy", "by": seconds])
        showToast(seconds > 0 ? "快进 \(Int(seconds)) 秒" : "快退 \(Int(-seconds)) 秒", duration: 1)
    }

    /// 用 Apple TV 原生播放器全屏播放；拿不到视频地址或原生播放失败时，改用网页内全屏。
    func playVideoFullscreen() {
        guard presentedViewController == nil, nativePlayer == nil else { return }
        guard let url = mediaURL else {
            if currentVideo != nil { enterWebFullscreen() } else { showToast("这个页面上没有找到视频") }
            return
        }
        if webFullscreen { exitWebFullscreen() }
        sendVideoCommand(["cmd": "pause"])
        let web = currentVideo
        let startAt = (web?.d ?? -1) > 0 ? (web?.t ?? 0) : 0
        let player = NativeVideoPlayer()
        player.onNext = { [weak self] in
            guard let self else { return }
            self.nativePlayer = nil
            guard let next = self.nextEpisodeURL else { return }
            self.autoPlayNextUntil = Date().addingTimeInterval(60)
            self.webView?.loadURL(next)
            self.showToast("正在打开下一集…")
        }
        player.onFailure = { [weak self] message, tryWeb in
            guard let self else { return }
            self.nativePlayer = nil
            self.lastPlaybackFailure = message
            if tryWeb {
                self.showToast("原生播放器播不了这个视频（\(message)），改用网页内全屏", duration: 4)
                self.enterWebFullscreen()
            } else {
                self.showToast(message, duration: 5)
            }
        }
        player.onClose = { [weak self] seconds in
            guard let self else { return }
            self.nativePlayer = nil
            if seconds > 1 { self.sendVideoCommand(["cmd": "seekTo", "t": seconds]) }
        }
        nativePlayer = player
        let media = NativeVideoPlayer.Media(url: url, referer: webView?.url, title: videoTitle,
                                            startAt: startAt, hasNext: nextEpisodeURL != nil)
        player.present(media, from: self)
    }

    /// 网页内全屏：把网页里的播放器放大铺满屏幕，用遥控器控制。
    func enterWebFullscreen() {
        guard !webFullscreen else { return }
        webFullscreen = true
        sendVideoCommand(["cmd": "fsEnter"])
        cursorView.isHidden = true
        view.setNeedsLayout()
        showToast("网页内全屏：按下触控板暂停/播放 · 左右键快退快进 · 上键播放选项 · 返回键退出", duration: 4)
    }

    func exitWebFullscreen() {
        guard webFullscreen else { return }
        webFullscreen = false
        sendVideoCommand(["cmd": "fsExit"])
        cursorView.isHidden = false
        view.setNeedsLayout()
    }

    private func handleFullscreenSwipe(_ gesture: UIPanGestureRecognizer, translation: CGPoint) {
        switch gesture.state {
        case .began:
            fullscreenSwipe = 0
        case .changed:
            fullscreenSwipe = translation.x
        case .ended:
            let seconds = (fullscreenSwipe / 12).rounded()
            if abs(seconds) >= 3 { seekWebVideo(by: Double(seconds)) }
            fullscreenSwipe = 0
        default:
            fullscreenSwipe = 0
        }
    }

    private func showVideoOptions() {
        var actions: [(String, () -> Void)] = []
        actions.append(("⏯  暂停 / 播放", { [weak self] in self?.sendVideoCommand(["cmd": "toggle"]) }))
        actions.append(("⏪  快退 30 秒", { [weak self] in self?.seekWebVideo(by: -30) }))
        actions.append(("⏩  快进 30 秒", { [weak self] in self?.seekWebVideo(by: 30) }))
        for rate in [0.75, 1.0, 1.25, 1.5, 2.0] {
            actions.append(("倍速 \(rate == 1 ? "1" : String(rate))×", { [weak self] in
                self?.sendVideoCommand(["cmd": "rate", "rate": rate])
            }))
        }
        if let next = nextEpisodeURL {
            actions.append(("⏭  下一集", { [weak self] in
                self?.exitWebFullscreen()
                self?.autoPlayNextUntil = Date().addingTimeInterval(60)
                self?.webView?.loadURL(next)
            }))
        }
        if mediaURL != nil {
            actions.append(("📺  改用原生播放器", { [weak self] in self?.playVideoFullscreen() }))
        }
        actions.append(("↩︎  退出全屏", { [weak self] in self?.exitWebFullscreen() }))
        showSheet(title: "播放选项", message: videoTitle, actions: actions)
    }

    /// 处理视频脚本的汇报。
    private func handleVideoReport(_ json: String) {
        guard let data = json.data(using: .utf8),
              let report = try? JSONDecoder().decode(FrameReport.self, from: data) else { return }
        if report.top {
            if topReport?.href != report.href {
                // 主页面换了：清掉旧页面的视频信息
                frameReports = [:]
                if webFullscreen { exitWebFullscreen() }
            }
            topReport = report
        }
        if report.video != nil {
            frameReports[report.href] = report
        } else {
            frameReports.removeValue(forKey: report.href)
        }
        reactToVideoState()
    }

    private func reactToVideoState() {
        guard let page = topReport?.href, hasVideo, presentedViewController == nil, nativePlayer == nil, !webFullscreen else { return }
        // 从播放器里点了「下一集」：新页面一有视频就接着全屏播放
        if let until = autoPlayNextUntil, Date() < until, mediaURL != nil {
            autoPlayNextUntil = nil
            autoPlayedPages.insert(page)
            playVideoFullscreen()
            return
        }
        if store.autoFullscreen, currentVideo?.paused == false, mediaURL != nil, !autoPlayedPages.contains(page) {
            autoPlayedPages.insert(page)
            playVideoFullscreen()
            return
        }
        if !hintedVideoPages.contains(page) {
            hintedVideoPages.insert(page)
            showToast("找到视频：按 ⏯ 播放/暂停键全屏播放", duration: 3.5)
        }
    }
}

// MARK: - 网页事件

extension BrowserViewController: TBWebViewDelegate {
    /// 自检、界面测试用的本地测试页，不记进历史。
    static func isTestPage(_ url: String) -> Bool {
        let host = URL(string: url)?.host ?? ""
        return host == "selftest.local" || host == "uitest.local"
    }

    func webViewStateDidChange(_ webView: TBWebView) {
        updateTopBar()
        applySiteZoomIfNeeded()
        // 网站用自己的脚本换页（不是真的打开新页面）进了小红书直播间：用手机版重新打开一次
        if let url = webView.url, SiteRules.prefersMobile(url), webView.customUserAgent != UserAgent.mobile,
           url != mobileReloadURL {
            mobileReloadURL = url
            webView.loadURL(url)
        }
        // 标题比「加载完成」来得晚时，补到历史记录里
        if let url = currentPageURLString, let title = webView.title, !title.isEmpty, !Self.isTestPage(url) {
            store.updateHistoryTitle(title, for: url)
        }
    }

    func webView(_ webView: TBWebView, didReceiveScriptMessage body: Any) {
        if let json = body as? String { handleVideoReport(json) }
    }

    func webView(_ webView: TBWebView, userAgentFor url: URL) -> String? {
        if SiteRules.prefersMobile(url) { return UserAgent.mobile }
        return store.desktopMode ? UserAgent.desktop : UserAgent.mobile
    }

    func webView(_ webView: TBWebView, didBlockPopup url: URL) {
        blockedPopups += 1
        debugLog("blocked popup \(url.absoluteString)")
    }

    func webViewDidFinishLoad(_ webView: TBWebView) {
        updateTopBar()
        #if DEBUG
        // 调试工具：启动参数 -probeJS "<脚本>" 会在每个页面加载完 3 秒后运行这段脚本，结果写进日志（PROBE 开头）
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-probeNative") {
            let info = webView.debugNativeInteractionInfo()
            var index = 0
            var rest = Substring(info)
            while !rest.isEmpty {
                NSLog("NATIVE%03d %@", index, String(rest.prefix(700)))
                rest = rest.dropFirst(700)
                index += 1
            }
        }
        if let i = args.firstIndex(of: "-probeJS"), i + 1 < args.count {
            let script = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak webView] in
                webView?.evaluateJavaScript(script) { result, error in
                    NSLog("PROBE %@ %@", String(describing: result ?? "nil"), error.map { String(describing: $0) } ?? "")
                }
            }
        }
        #endif
        if let callback = onFinishLoad {
            onFinishLoad = nil
            callback()
        }
        if let url = currentPageURLString, !Self.isTestPage(url) {
            store.lastURL = url
            store.recordVisit(title: webView.title ?? "", url: url)
        }
    }

    func webView(_ webView: TBWebView, didFailWithError error: Error) {
        updateTopBar()
        showToast("网页打开失败：\(error.localizedDescription)", duration: 4)
    }

    func webView(_ webView: TBWebView, didRequestAppURL url: URL) {
        switch url.host ?? "" {
        case "search": showAddressInput()
        case "bookmarks": showBookmarks()
        case "history": showHistory()
        case "clear-history": confirmClearHistory()
        case "menu": showMenu()
        case "help": showHelp()
        default: break
        }
    }

    func webView(_ webView: TBWebView, showAlert message: String, completion: @escaping () -> Void) {
        let once = CallOnce<Void>(fallback: ()) { completion() }
        guard presentedViewController == nil else { once.call(()); return }
        let alert = UIAlertController(title: webView.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .cancel) { _ in once.call(()) })
        present(alert, animated: true)
    }

    func webView(_ webView: TBWebView, showConfirm message: String, completion: @escaping (Bool) -> Void) {
        let once = CallOnce<Bool>(fallback: false, completion)
        guard presentedViewController == nil else { once.call(false); return }
        let alert = UIAlertController(title: webView.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in once.call(true) })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in once.call(false) })
        present(alert, animated: true)
    }

    func webView(_ webView: TBWebView, showPrompt message: String, defaultText: String?, completion: @escaping (String?) -> Void) {
        let once = CallOnce<String?>(fallback: nil, completion)
        guard presentedViewController == nil else { once.call(nil); return }
        let alert = UIAlertController(title: webView.url?.host, message: message, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak alert] _ in once.call(alert?.textFields?.first?.text ?? "") })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in once.call(nil) })
        present(alert, animated: true)
    }
}

extension BrowserViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - 自检（只在调试版本里存在）
// 启动参数带 -selftest 时，App 会在真实的 tvOS 网页引擎里自动走一遍光标点击、输入、选择、滚动等功能，
// 每一项结果打印成 “SELFTEST PASS/FAIL 名称 详情”。模拟器没法模拟遥控器触控板滑动，所以用这种方式测试。

#if DEBUG
extension BrowserViewController {
    /// 界面测试页：屏幕中央是一个大链接（光标默认就在那里），点了会打开 example.com；
    /// 网页标题反映当前状态，界面测试通过顶栏标题读取。
    fileprivate static let uiTestPage = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1"><title>第一页</title>
    <style>body{margin:0;font:40px sans-serif;background:#fff}
    #go{position:absolute;left:660px;top:330px;width:600px;height:300px;display:flex;align-items:center;
    justify-content:center;background:#2f6feb;color:#fff;text-decoration:none;border-radius:30px}</style></head>
    <body><a id="go" href="https://example.com/">打开 example.com</a><div style="height:6000px"></div>
    <script>
    window.addEventListener('scroll', function(){ document.title = '滚动到 ' + Math.round(window.scrollY); });
    </script></body></html>
    """

    private static let selfTestPage = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1"><title>自检页</title>
    <style>body{margin:0;font:28px sans-serif;background:#fff;color:#000}
    .a{position:absolute;box-sizing:border-box;margin:0}</style></head><body>
    <form id="f" onsubmit="event.preventDefault(); window.submits=(window.submits||0)+1;">
    <input id="name" class="a" style="left:60px;top:40px;width:500px;height:70px;font-size:28px" placeholder="用户名"></form>
    <select id="sel" class="a" style="left:60px;top:150px;width:300px;height:60px;font-size:28px">
    <option>A</option><option>B</option><option value="C">C</option><option>D</option></select>
    <button id="btn" class="a" style="left:60px;top:260px;width:240px;height:80px;font-size:28px">按钮</button>
    <div id="scroller" class="a" style="left:60px;top:380px;width:500px;height:300px;overflow:auto;background:#eee">
    <div style="height:2000px">内部滚动区</div></div>
    <iframe id="fr" class="a" style="left:700px;top:40px;width:500px;height:200px;border:0"
     srcdoc="<body style='margin:0'><button id='ib' style='width:300px;height:100px;font-size:28px'>框架内按钮</button><script>window.ic=0;document.getElementById('ib').onclick=function(){window.ic++}</script></body>"></iframe>
    <input id="pw" type="password" class="a" style="left:700px;top:300px;width:400px;height:60px" aria-label="密码">
    <iframe id="xo" class="a" style="left:700px;top:420px;width:400px;height:160px;border:0"
     src="data:text/html,%3Cbody%20style%3D%22margin%3A0%22%3E%3Cbutton%20style%3D%22width%3A400px%3Bheight%3A160px%3Bfont-size%3A28px%22%20onclick%3D%22parent.postMessage('xo-clicked'%2C'*')%22%3E%E5%A4%96%E7%AB%99%E6%8C%89%E9%92%AE%3C%2Fbutton%3E%3C%2Fbody%3E"></iframe>
    <script>window.xoClicked=0;window.addEventListener('message',function(e){if(e.data==='xo-clicked'){window.xoClicked++;}});</script>
    <script>window.md=0;window.cl=0;var b=document.getElementById('btn');
    b.addEventListener('mousedown',function(){md++});b.addEventListener('click',function(){cl++});</script>
    </body></html>
    """

    private func stLog(_ name: String, _ ok: Bool, _ detail: String = "") {
        NSLog("SELFTEST %@ %@ %@", ok ? "PASS" : "FAIL", name, detail)
    }

    private func stJS(_ script: String) async -> Any? {
        guard let wv = webView else { return nil }
        return await withCheckedContinuation { cont in
            wv.evaluateJavaScript(script) { result, _ in cont.resume(returning: result) }
        }
    }

    private func stWait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func stWaitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await stWait(0.5)
        }
        return condition()
    }

    private static let nativeClickTestPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>原生点击自检</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>body{margin:0;background:#fff;font:28px sans-serif}.a{position:absolute;box-sizing:border-box}</style></head><body>
    <button id="nb" class="a" style="left:200px;top:200px;width:400px;height:160px;font-size:32px">原生点击按钮</button>
    <input id="nc" type="checkbox" class="a" style="left:800px;top:240px;width:60px;height:60px">
    <iframe id="nx" class="a" style="left:200px;top:500px;width:500px;height:200px;border:0"
     src="data:text/html,%3Cbody%20style%3D%22margin%3A0%22%3E%3Cbutton%20id%3D%22b%22%20style%3D%22width%3A500px%3Bheight%3A200px%3Bfont-size%3A28px%22%3E%E5%A4%96%E7%AB%99%E6%8C%89%E9%92%AE%3C%2Fbutton%3E%3Cscript%3Edocument.getElementById('b').addEventListener('click'%2Cfunction(e)%7Bparent.postMessage(%7Bxo%3A1%2Ctrusted%3Ae.isTrusted%7D%2C'*')%7D)%3C%2Fscript%3E%3C%2Fbody%3E"></iframe>
    <script>
    window.nb = {down: 0, click: 0, trusted: null};
    var b = document.getElementById('nb');
    b.addEventListener('mousedown', function(e){ nb.down++; });
    b.addEventListener('click', function(e){ nb.click++; nb.trusted = e.isTrusted; });
    window.nc = {trusted: null};
    document.getElementById('nc').addEventListener('click', function(e){ nc.trusted = e.isTrusted; });
    window.nx = {clicks: 0, trusted: null};
    window.addEventListener('message', function(e){ if (e.data && e.data.xo) { nx.clicks++; nx.trusted = e.data.trusted; } });
    </script></body></html>
    """

    private static let mediaTestPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>视频自检页</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>body{margin:0;background:#fff;font:28px sans-serif}</style></head><body>
    <div style="position:relative;transform:translateZ(0)"><video id="v" muted autoplay playsinline
      src="https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8"
      style="width:960px;height:540px;display:block"></video></div>
    <a id="ext" href="https://ads.example.net/promo"><img alt="ad" style="width:800px;height:120px;background:#c00;display:block"
      src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"></a>
    <a id="int" href="https://selftest.local/page2" style="display:block;width:800px;height:120px;background:#0c0">站内链接</a>
    </body></html>
    """

    /// 发起加载后等它完成，最多等 timeout 秒。
    private func stLoad(timeout: Double = 25, _ start: () -> Void) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var done = false
            onFinishLoad = {
                guard !done else { return }
                done = true
                cont.resume(returning: true)
            }
            start()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard !done else { return }
                done = true
                self?.onFinishLoad = nil
                cont.resume(returning: false)
            }
        }
    }

    /// 网页元素中心点在屏幕上的位置。
    private func stCenter(_ selector: String) async -> CGPoint? {
        guard let wv = webView else { return nil }
        let js = """
        (function(){var e=document.querySelector(\(PageScripts.jsString(selector)));if(!e)return '';
        var r=e.getBoundingClientRect();return JSON.stringify([r.left+r.width/2,r.top+r.height/2,window.innerWidth]);})()
        """
        guard let s = await stJS(js) as? String, let data = s.data(using: .utf8),
              let a = try? JSONDecoder().decode([Double].self, from: data), a.count == 3, a[2] > 0 else { return nil }
        let scale = wv.bounds.width / CGFloat(a[2])
        return wv.convert(CGPoint(x: CGFloat(a[0]) * scale, y: CGFloat(a[1]) * scale), to: view)
    }

    private func stClick(_ selector: String) async -> ClickResult? {
        guard let p = await stCenter(selector) else { return nil }
        cursorPoint = p
        placeCursor()
        return await withCheckedContinuation { cont in
            clickAtCursor { cont.resume(returning: $0) }
        }
    }

    private func stDismissAlert() async -> String? {
        guard let alert = presentedViewController as? UIAlertController else { return nil }
        let title = alert.title ?? ""
        await withCheckedContinuation { cont in alert.dismiss(animated: false) { cont.resume() } }
        return title
    }

    func runSelfTest() async {
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            stLog(name, ok, detail)
            if ok { passed += 1 } else { failed += 1 }
        }
        NSLog("SELFTEST START")
        guard let wv = webView else {
            check("找到 WebKit 网页引擎", false)
            NSLog("SELFTEST DONE passed=0 failed=1")
            return
        }
        check("找到 WebKit 网页引擎", true)

        // 1. 起始页
        let startLoaded = await stLoad { showStartPage() }
        check("起始页加载", startLoaded && isOnStartPage, "url=\(wv.url?.absoluteString ?? "nil")")
        let startTiles = await stJS("document.querySelectorAll('.tile:not(.live-tile)').length") as? Int ?? -1
        check("起始页显示收藏格子", startTiles == store.bookmarks.count, "tiles=\(startTiles) bookmarks=\(store.bookmarks.count)")
        let liveTiles = await stJS("document.querySelectorAll('.live-tile').length") as? Int ?? -1
        check("起始页显示「直播」专区", liveTiles == SiteRules.liveChannels.count, "tiles=\(liveTiles)")
        let recentRows = await stJS("document.querySelectorAll('.row').length") as? Int ?? -1
        let expectedRows = min(store.history.count, StartPage.recentLimit)
        check("起始页显示「最近看过」", recentRows == expectedRows, "rows=\(recentRows) expected=\(expectedRows)")
        _ = await stClick(".search")
        await stWait(1.0)
        let searchAlert = await stDismissAlert()
        check("点起始页搜索框弹出地址输入", searchAlert == "输入网址或搜索", "alert=\(searchAlert ?? "nil")")

        // 2. 自检页：点击、输入、下拉框、框架
        let pageLoaded = await stLoad { wv.loadHTMLString(Self.selfTestPage, baseURL: URL(string: "https://selftest.local/")) }
        await stWait(0.5)
        check("自检页加载", pageLoaded && wv.title == "自检页", "title=\(wv.title ?? "nil")")
        check("顶栏显示网页标题", titleLabel.text == "自检页", "label=\(titleLabel.text ?? "nil")")
        let innerWidth = await stJS("window.innerWidth") as? Double ?? -1
        check("网页铺满屏幕宽度（没有左右黑边）", abs(innerWidth - Double(wv.bounds.width)) < 1 && wv.bounds.width == view.bounds.width,
              "innerWidth=\(innerWidth) webView=\(wv.bounds.width) screen=\(view.bounds.width)")
        check("网页视图没有安全区边距", wv.safeAreaInsets == .zero, "\(wv.safeAreaInsets)")

        let r1 = await stClick("#name")
        check("点输入框识别为文字输入", r1?.kind == "text" && r1?.label == "用户名", "kind=\(r1?.kind ?? "nil") label=\(r1?.label ?? "nil")")
        _ = await stJS(PageScripts.setText("你好 Apple TV \"引号\"", submit: true))
        let value = await stJS("document.getElementById('name').value") as? String
        let submits = await stJS("window.submits||0") as? Int
        check("填入文字并提交表单", value == "你好 Apple TV \"引号\"" && submits == 1, "value=\(value ?? "nil") submits=\(submits ?? -1)")

        let r2 = await stClick("#sel")
        check("点下拉框列出选项", r2?.kind == "select" && r2?.options?.count == 4, "kind=\(r2?.kind ?? "nil") n=\(r2?.options?.count ?? -1)")
        _ = await stJS(PageScripts.selectOption(2))
        let selValue = await stJS("document.getElementById('sel').value") as? String
        check("选中下拉框第 3 项", selValue == "C", "value=\(selValue ?? "nil")")

        let r3 = await stClick("#btn")
        let md = await stJS("window.md") as? Int, cl = await stJS("window.cl") as? Int
        check("点按钮只触发一次", r3?.kind == "click" && md == 1 && cl == 1, "md=\(md ?? -1) cl=\(cl ?? -1)")

        if let frameCenter = await stCenter("#fr") {
            cursorPoint = CGPoint(x: frameCenter.x - 100, y: frameCenter.y - 60)
            placeCursor()
            _ = await withCheckedContinuation { cont in clickAtCursor { cont.resume(returning: $0) } }
        }
        let ic = await stJS("document.getElementById('fr').contentWindow.ic") as? Int
        check("点进内嵌框架里的按钮", ic == 1, "ic=\(ic ?? -1)")

        let xoAccess = await stJS("(function(){try{return document.getElementById('xo').contentDocument?'same':'cross'}catch(e){return 'cross'}})()") as? String
        let rXO = await stClick("#xo")
        await stWait(1.0)
        let xoClicked = await stJS("window.xoClicked") as? Int ?? -1
        check("点进其他网站的框架里的按钮", xoAccess == "cross" && rXO?.kind == "forwarded" && xoClicked == 1,
              "frame=\(xoAccess ?? "nil") kind=\(rXO?.kind ?? "nil") clicked=\(xoClicked)")

        let r4 = await stClick("#pw")
        check("密码框识别为密码", r4?.kind == "text" && r4?.secure == true, "secure=\(String(describing: r4?.secure))")

        // 3. 滚动：整页不能滚时滚内部区域；整页能滚时滚整页
        if let p = await stCenter("#scroller") {
            cursorPoint = p
            placeCursor()
        }
        scroll(dx: 0, dy: 150)
        await stWait(0.5)
        let innerTop = await stJS("document.getElementById('scroller').scrollTop") as? Int ?? -1
        check("整页不能滚时滚动内部区域", innerTop > 0, "scrollTop=\(innerTop)")

        _ = await stJS("var d=document.createElement('div');d.style.height='5000px';d.style.position='absolute';d.style.top='800px';d.style.width='10px';document.body.appendChild(d);1")
        await stWait(0.8)
        let sv = wv.scrollView
        let before = sv?.contentOffset.y ?? 0
        pageDown()
        await stWait(0.8)
        let afterPage = sv?.contentOffset.y ?? 0
        check("外圈向下翻页", afterPage > before + 300, "offset \(Int(before)) → \(Int(afterPage))")

        cursorPoint = CGPoint(x: view.bounds.midX, y: view.bounds.height - 4)
        placeCursor()
        moveCursor(by: CGPoint(x: 0, y: 60))
        await stWait(0.3)
        let afterEdge = sv?.contentOffset.y ?? 0
        check("光标推到底边自动滚动", afterEdge > afterPage, "offset \(Int(afterPage)) → \(Int(afterEdge))")
        check("光标停在屏幕内", cursorPoint.y <= view.bounds.height - 4, "y=\(Int(cursorPoint.y))")

        setMode(.scroll)
        check("播放键切换到滚动模式", mode == .scroll && cursorView.alpha < 0.5)
        let r5Before = sv?.contentOffset.y ?? 0
        scroll(dx: 0, dy: -200)
        let r5After = sv?.contentOffset.y ?? 0
        check("滚动模式向上滚", r5After < r5Before, "offset \(Int(r5Before)) → \(Int(r5After))")
        setMode(.cursor)

        // 4. 缩放后坐标仍然对得上
        let ua = await stJS("navigator.userAgent") as? String ?? ""
        check("默认使用电脑版 User-Agent", ua.contains("Macintosh"), ua)
        _ = await stJS("window.scrollTo(0,0);1")
        await stWait(0.5)
        wv.pageZoom = 1.5
        await stWait(0.8)
        let r6 = await stClick("#btn")
        let cl2 = await stJS("window.cl") as? Int
        check("放大 150% 后点击位置仍准确", r6?.kind == "click" && cl2 == 2, "cl=\(cl2 ?? -1)")
        wv.pageZoom = CGFloat(store.pageZoom)

        // 5. 网页弹框
        _ = await stJS("setTimeout(function(){alert('来自网页的提示')},0);1")
        await stWait(1.0)
        let alertShown = (presentedViewController as? UIAlertController)?.message
        check("网页 alert 显示为系统弹框", alertShown == "来自网页的提示", "message=\(alertShown ?? "nil")")
        _ = await stDismissAlert()
        await stWait(0.5)
        _ = await stJS("setTimeout(function(){window.confirmResult=String(confirm('继续吗？'))},0);1")
        await stWait(1.0)
        let confirmShown = presentedViewController is UIAlertController
        _ = await stDismissAlert()
        await stWait(0.5)
        let confirmResult = await stJS("window.confirmResult") as? String
        check("网页 confirm 弹框被关掉时按取消处理、不闪退", confirmShown && confirmResult == "false", "result=\(confirmResult ?? "nil")")

        // 5b. 从本地生成的页面（起始页就是这样加载的）点进网站，再后退回来
        let uiLoaded = await stLoad { wv.loadHTMLString(Self.uiTestPage, baseURL: URL(string: "https://uitest.local/")) }
        cursorPoint = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        placeCursor()
        let leftLocal = await stLoad(timeout: 25) { clickAtCursor { _ in } }
        check("从本地页面点链接进入网站", uiLoaded && leftLocal && wv.title == "Example Domain",
              "title=\(wv.title ?? "nil") canGoBack=\(wv.canGoBack)")
        check("没有后退记录时，返回键留在 App 里", backPressStaysInApp)
        let backToStart = await stLoad { goBackOrToStartPage() }
        check("没有后退记录时，返回键回到起始页", backToStart && isOnStartPage, "url=\(wv.url?.absoluteString ?? "nil")")
        check("在起始页时，返回键交给系统退出 App", !backPressStaysInApp)

        // 6. 真实网站
        let ex = await stLoad { open("example.com") }
        check("打开 example.com", ex && wv.title == "Example Domain", "title=\(wv.title ?? "nil")")
        _ = await stJS("var a=document.createElement('a');a.id='hashlink';a.href='#part2';a.textContent='页内跳转';a.style.cssText='position:fixed;left:0;top:0;width:400px;height:200px;background:#fc0;font-size:40px;z-index:99';document.body.appendChild(a);1")
        await stWait(0.3)
        let lenBefore = await stJS("history.length") as? Int ?? -1
        _ = await stClick("#hashlink")
        await stWait(0.8)
        let lenAfter = await stJS("history.length") as? Int ?? -1
        check("真实网页上点锚点链接会新增历史记录", lenAfter == lenBefore + 1 && wv.canGoBack,
              "history \(lenBefore) → \(lenAfter) canGoBack=\(wv.canGoBack) hash=\(wv.url?.fragment ?? "nil")")
        if wv.canGoBack && wv.url?.fragment == "part2" {
            wv.goBack()
            await stWait(0.8)
            check("真实网页锚点后退", wv.url?.fragment == nil && wv.url?.host == "example.com", "url=\(wv.url?.absoluteString ?? "nil")")
        }
        _ = await stJS("document.getElementById('hashlink').remove();1")
        if let link = await stClick("a") {
            NSLog("SELFTEST info link click kind=%@", link.kind)
        }
        let followed = await stLoad(timeout: 25) {}
        check("点链接跳转到新页面", followed && wv.url?.host != "example.com", "url=\(wv.url?.absoluteString ?? "nil")")
        let back = await stLoad { wv.goBack() }
        check("后退回到上一页", back && wv.url?.host == "example.com", "url=\(wv.url?.absoluteString ?? "nil")")
        let search = await stLoad(timeout: 30) { open("Apple TV") }
        check("输入文字用搜索引擎搜索", search && (wv.url?.absoluteString.contains("q=Apple") ?? false), "url=\(wv.url?.absoluteString ?? "nil")")
        let wiki = await stLoad(timeout: 30) { open("zh.wikipedia.org") }
        check("打开中文维基百科", wiki && (wv.url?.host?.contains("wikipedia") ?? false), "title=\(wv.title ?? "nil")")
        let history = store.history.first?.url ?? ""
        check("历史记录写入", history.contains("wikipedia"), history)

        // 8. 光标灵敏度：慢慢滑时比原来精细，快速滑时仍然够快
        let speed = CGFloat(Store.defaultCursorSpeed)
        let slowGain = Self.cursorGain(forDelta: 2, speed: speed)
        let fastGain = Self.cursorGain(forDelta: 40, speed: speed)
        check("光标慢速微调更精细", slowGain < 0.3, "gain=\(slowGain)")
        check("光标快速滑动仍然够快", fastGain > 0.85, "gain=\(fastGain)")
        check("光标是圆点，点击位置在圆心", Cursor.hotspot.x == Cursor.hotspot.y && cursorView.image?.size.width == Cursor.hotspot.x * 2)

        // 9. 去广告、拦弹窗、视频检测
        frameReports = [:]
        topReport = nil
        let mediaLoaded = await stLoad { wv.loadHTMLString(Self.mediaTestPage, baseURL: URL(string: "https://selftest.local/")) }
        await stWait(2.5)
        let extHidden = await stJS("getComputedStyle(document.getElementById('ext')).display") as? String
        let intShown = await stJS("getComputedStyle(document.getElementById('int')).display") as? String
        check("去广告：外站图片广告被隐藏、站内链接保留", mediaLoaded && extHidden == "none" && intShown == "block",
              "ext=\(extHidden ?? "nil") int=\(intShown ?? "nil")")
        let popupsBefore = blockedPopups
        let urlBefore = wv.url?.absoluteString
        _ = await stJS("window.open('https://ads.example.net/popup'); 1")
        await stWait(1.5)
        check("拦截网页自己弹出的外站窗口", blockedPopups == popupsBefore + 1 && wv.url?.absoluteString == urlBefore,
              "blocked=\(blockedPopups - popupsBefore) url=\(wv.url?.absoluteString ?? "nil")")
        let found = await stWaitUntil(20) { self.mediaURL?.absoluteString.contains("bipbop") == true }
        check("检测到网页视频和它的播放地址", found && hasVideo, "url=\(mediaURL?.absoluteString ?? "nil")")

        // 10. 原生全屏播放器
        if found {
            playVideoFullscreen()
            let ready = await stWaitUntil(25) { self.nativePlayer?.itemStatus == .readyToPlay }
            check("原生播放器能播放网页视频", ready && presentedViewController is AVPlayerViewController,
                  "status=\(String(describing: nativePlayer?.itemStatus.rawValue))")
            nativePlayer?.close()
            let closed = await stWaitUntil(5) { self.nativePlayer == nil && self.presentedViewController == nil }
            check("关闭原生播放器回到网页", closed)
        }

        // 11. 网页内全屏
        enterWebFullscreen()
        await stWait(1.5)
        let fsInfo = await stJS("(function(){var v=document.getElementById('v');var r=v.getBoundingClientRect();return getComputedStyle(v).position+' '+Math.round(r.width)+' '+window.innerWidth;})()") as? String ?? ""
        let fsParts = fsInfo.split(separator: " ")
        check("网页内全屏：视频铺满屏幕、顶栏隐藏", fsParts.count == 3 && fsParts[0] == "fixed" && fsParts[1] == fsParts[2] && topBar.isHidden, fsInfo)
        exitWebFullscreen()
        await stWait(1.0)
        let restored = await stJS("getComputedStyle(document.getElementById('v')).position") as? String
        check("退出网页内全屏后恢复原样", restored == "static" && !topBar.isHidden, "position=\(restored ?? "nil")")

        // 12. 欧乐：去广告、缩放、找到播放地址和下一集、原生播放
        let oleHome = await stLoad(timeout: 30) { wv.loadURL(URL(string: "https://www.olehdtv.com/")!) }
        await stWait(6)
        let oleAds = await stJS("""
        (function(){var n=0;document.querySelectorAll('a[href^="http"]').forEach(function(a){try{var h=new URL(a.href).hostname;
        if(!/olehdtv|olelive|olevod|oulehdtv/.test(h)){var r=a.getBoundingClientRect();if(r.width>0&&r.height>0&&getComputedStyle(a).visibility!=='hidden')n++;}}catch(e){}});
        var modal=document.getElementById('notice_fixed');return n+' '+(modal?getComputedStyle(modal).display:'none');})()
        """) as? String ?? "?"
        check("欧乐首页：看不到外站广告和 VIP 弹窗", oleHome && oleAds == "0 none", "visibleAds+modal=\(oleAds)")
        let oleFit = await stJS("Math.round(document.documentElement.getBoundingClientRect().width)+' '+innerWidth") as? String ?? "?"
        let oleParts = oleFit.split(separator: " ")
        check("欧乐页面正好铺满屏幕、没有被裁掉", abs(wv.pageZoom - 1) < 0.01 && oleParts.count == 2 && oleParts[0] == oleParts[1], "zoom=\(wv.pageZoom) html/innerWidth=\(oleFit)")
        frameReports = [:]
        topReport = nil
        let olePlay = await stLoad(timeout: 30) { wv.loadURL(URL(string: "https://www.olehdtv.com/index.php/vod/play/id/85663/sid/1/nid/1.html")!) }
        let oleMedia = await stWaitUntil(25) { self.mediaURL?.absoluteString.contains(".m3u8") == true }
        let oleSideAds = await stJS("[].slice.call(document.querySelectorAll('.ads,.right_ads')).filter(function(e){return e.getBoundingClientRect().height>0}).length") as? Int ?? -1
        check("欧乐播放页：右侧广告位被隐藏", oleSideAds == 0, "visible=\(oleSideAds)")
        check("欧乐播放页：找到视频地址和下一集", olePlay && oleMedia && (nextEpisodeURL?.absoluteString.contains("nid/2") ?? false),
              "media=\(mediaURL?.absoluteString.prefix(80) ?? "nil") next=\(nextEpisodeURL?.absoluteString ?? "nil")")
        if oleMedia {
            playVideoFullscreen()
            let ready = await stWaitUntil(30) { self.nativePlayer?.itemStatus == .readyToPlay }
            check("欧乐视频用原生播放器播放", ready, "status=\(String(describing: nativePlayer?.itemStatus.rawValue))")
            nativePlayer?.close()
            _ = await stWaitUntil(5) { self.nativePlayer == nil && self.presentedViewController == nil }
        }

        // 13. 酷播：去广告、找到播放地址、原生播放
        frameReports = [:]
        topReport = nil
        let kubbPlay = await stLoad(timeout: 30) { wv.loadURL(URL(string: "https://www.kubb.tv/play/X4r3180qOd2")!) }
        let kubbMedia = await stWaitUntil(30) { self.mediaURL?.absoluteString.contains(".m3u8") == true }
        let kubbAds = await stJS("""
        (function(){var n=0;document.querySelectorAll('a[href*="ppt.kubb.tv/c/"]').forEach(function(a){var r=a.getBoundingClientRect();if(r.width>0&&r.height>0)n++;});return n;})()
        """) as? Int ?? -1
        check("酷播播放页：广告被隐藏", kubbPlay && kubbAds == 0, "visibleAds=\(kubbAds)")
        let kubbFit = await stJS("Math.round(document.documentElement.getBoundingClientRect().width)+' '+innerWidth") as? String ?? "?"
        let kubbParts = kubbFit.split(separator: " ")
        check("酷播页面正好铺满屏幕、没有被裁掉", abs(wv.pageZoom - 1) < 0.01 && kubbParts.count == 2 && kubbParts[0] == kubbParts[1], "zoom=\(wv.pageZoom) html/innerWidth=\(kubbFit)")
        check("酷播播放页：找到视频地址", kubbMedia, "media=\(mediaURL?.absoluteString.prefix(80) ?? "nil")")
        if kubbMedia {
            playVideoFullscreen()
            let ready = await stWaitUntil(30) { self.nativePlayer?.itemStatus == .readyToPlay }
            check("酷播视频用原生播放器播放", ready, "status=\(String(describing: nativePlayer?.itemStatus.rawValue))")
            nativePlayer?.close()
            _ = await stWaitUntil(5) { self.nativePlayer == nil && self.presentedViewController == nil }
        }

        // 15. 直播：CGTN 在爱尔兰能播；播不了的直播要自动退出并提示，不能停在黑屏
        frameReports = [:]
        topReport = nil
        _ = await stLoad(timeout: 30) { wv.loadURL(URL(string: "https://www.cgtn.com/tv")!) }
        let cgtnMedia = await stWaitUntil(25) { self.mediaURL?.absoluteString.contains(".m3u8") == true }
        check("CGTN：找到直播地址", cgtnMedia, "media=\(mediaURL?.absoluteString.prefix(80) ?? "nil")")
        if cgtnMedia {
            playVideoFullscreen()
            let playing = await stWaitUntil(30) {
                guard let p = self.nativePlayer?.player else { return false }
                return p.timeControlStatus == .playing && p.currentTime().seconds > 1
            }
            check("CGTN：原生播放器播放直播、画面在动", playing, "time=\(nativePlayer?.player?.currentTime().seconds ?? -1)")
            nativePlayer?.close()
            _ = await stWaitUntil(5) { self.nativePlayer == nil && self.presentedViewController == nil }
        }

        frameReports = [:]
        topReport = nil
        lastPlaybackFailure = nil
        // RTHK 现在在网页上就直接拒绝香港以外的地区，拿不到视频地址了；改用一个不存在的直播地址，检查同一条退出路径
        let deniedPage = "<html><body><video controls src=\"https://english-livebkali.cgtn.com/live/tvb-selftest-missing.m3u8\"></video></body></html>"
        _ = await stLoad { wv.loadHTMLString(deniedPage, baseURL: URL(string: "https://selftest.local/denied")) }
        let deniedMedia = await stWaitUntil(10) { self.mediaURL?.absoluteString.contains("tvb-selftest-missing") == true }
        if deniedMedia {
            playVideoFullscreen()
            let exited = await stWaitUntil(35) { self.nativePlayer == nil && self.presentedViewController == nil }
            check("播不了的直播（地址失效 / 地区限制）：自动退出黑屏并提示原因", exited && lastPlaybackFailure != nil && !webFullscreen,
                  "exited=\(exited) reason=\(lastPlaybackFailure ?? "nil") webFullscreen=\(webFullscreen)")
        } else {
            check("播不了的直播（地址失效 / 地区限制）：自动退出黑屏并提示原因", false, "测试页没有找到视频")
        }

        // 16. 小红书直播：列表页用电脑版；进直播间自动换手机版，拿到 m3u8 用原生播放器播；离开后换回来
        frameReports = [:]
        topReport = nil
        let listLoaded = await stLoad(timeout: 30) { wv.loadURL(URL(string: "https://www.xiaohongshu.com/livelist")!) }
        await stWait(4)
        let roomHref = await stJS("(function(){var a=document.querySelector('a[href*=\"/livestream/\"]');return a?a.href:''})()") as? String ?? ""
        check("小红书直播列表：找到直播间", listLoaded && roomHref.contains("/livestream/") && (wv.customUserAgent?.contains("Macintosh") ?? false),
              "room=\(roomHref.prefix(80)) ua=\(wv.customUserAgent?.prefix(40) ?? "nil")")
        if !roomHref.isEmpty {
            // 像用户一样在列表里点进去：网站用自己的脚本换页，不会真的打开新页面
            frameReports = [:]
            topReport = nil
            _ = await stJS("document.querySelector('a[href*=\"/livestream/\"]').click(); 1")
            let mobileUA = await stWaitUntil(10) { self.webView?.customUserAgent?.contains("iPhone") == true }
            let roomMedia = await stWaitUntil(25) { self.mediaURL?.absoluteString.contains(".m3u8") == true }
            check("小红书直播间：自动换手机版，拿到 m3u8", mobileUA && roomMedia, "media=\(mediaURL?.absoluteString.prefix(80) ?? "nil")")
            if roomMedia {
                playVideoFullscreen()
                let playing = await stWaitUntil(30) {
                    guard let p = self.nativePlayer?.player else { return false }
                    return p.timeControlStatus == .playing && p.currentTime().seconds > 1
                }
                check("小红书直播间：原生播放器播放、画面在动", playing, "time=\(nativePlayer?.player?.currentTime().seconds ?? -1)")
                nativePlayer?.close()
                _ = await stWaitUntil(5) { self.nativePlayer == nil && self.presentedViewController == nil }
            }
            _ = await stLoad(timeout: 30) { wv.loadURL(URL(string: "https://example.com/")!) }
            check("离开直播间后换回电脑版", wv.customUserAgent?.contains("Macintosh") ?? false, "ua=\(wv.customUserAgent?.prefix(40) ?? "nil")")
        }

        NSLog("SELFTEST DONE passed=%d failed=%d", passed, failed)
    }
}
#endif
