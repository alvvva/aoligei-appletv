import AVKit
import UIKit

/// 用 Apple TV 原生播放器全屏播放网页里的视频。
/// 遥控器操作和系统其他视频 App 一样：按下触控板暂停/播放，左右滑动拖进度，向下滑打开信息面板（倍速等），
/// 传输栏里有「下一集」，播完自动下一集。
final class NativeVideoPlayer: NSObject, AVPlayerViewControllerDelegate {
    struct Media {
        let url: URL
        let referer: URL?
        let title: String
        /// 从第几秒开始播（接着网页里已经播到的位置），0 表示从头。
        let startAt: Double
        let hasNext: Bool
    }

    var onNext: (() -> Void)?
    /// 播放失败：提示文字，以及值不值得改用网页内全屏再试（服务器拒绝访问时没必要）。
    var onFailure: ((String, Bool) -> Void)?
    /// 关闭播放器时的播放位置（秒）。
    var onClose: ((Double) -> Void)?

    private enum Ending {
        case closed
        case next
        case failed(String, tryWeb: Bool)
    }

    let controller = AVPlayerViewController()
    private(set) var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var errorObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var watchdog: Timer?
    private var hasProgressed = false
    private var pendingEnding: Ending?
    private var ended = false

    /// 自检用：播放器条目当前状态。
    var itemStatus: AVPlayerItem.Status { player?.currentItem?.status ?? .unknown }

    func present(_ media: Media, from presenter: UIViewController) {
        var options: [String: Any] = [:]
        if let referer = media.referer {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Referer": referer.absoluteString]
        }
        let asset = AVURLAsset(url: media.url, options: options)
        let item = AVPlayerItem(asset: asset)
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = media.title as NSString
        title.extendedLanguageTag = "und"
        item.externalMetadata = [title]

        let player = AVPlayer(playerItem: item)
        self.player = player
        controller.player = player
        controller.delegate = self
        controller.speeds = AVPlaybackSpeed.systemDefaultSpeeds
        if media.hasNext {
            let next = UIAction(title: "下一集", image: UIImage(systemName: "forward.end.fill")) { [weak self] _ in
                self?.finish(.next)
            }
            controller.transportBarCustomMenuItems = [next]
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async {
                // 先看错误日志里有没有「拒绝访问」：有的话是地区限制，换网页全屏也没用
                if let message = Self.accessErrorMessage(in: item) {
                    self?.finish(.failed(message, tryWeb: false))
                } else {
                    self?.finish(.failed(item.error?.localizedDescription ?? "无法播放", tryWeb: true))
                }
            }
        }
        // 服务器拒绝访问（比如只对香港开放的直播）时，AVPlayer 会一直重试、停在黑屏，这里直接判定失败
        errorObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: .main) { [weak self] _ in
            guard let event = item.errorLog()?.events.last else { return }
            if let message = Self.accessErrorMessage(statusCode: event.errorStatusCode) {
                self?.finish(.failed(message, tryWeb: false))
            }
        }
        failObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            if let message = Self.accessErrorMessage(in: item) {
                self?.finish(.failed(message, tryWeb: false))
            } else {
                self?.finish(.failed(error?.localizedDescription ?? "播放中断", tryWeb: true))
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.finish(media.hasNext ? .next : .closed)
        }
        // 看门狗：打开 20 秒后画面还一点没动，就不再干等黑屏
        let openedAt = Date()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !self.ended, let player = self.player else { return }
            if player.timeControlStatus == .playing && player.currentTime().seconds > 0.3 { self.hasProgressed = true }
            guard !self.hasProgressed, Date().timeIntervalSince(openedAt) > 20 else { return }
            if let message = Self.accessErrorMessage(in: item) {
                self.finish(.failed(message, tryWeb: false))
            } else {
                self.finish(.failed(self.itemStatus == .unknown ? "加载超时" : "一直没有画面", tryWeb: true))
            }
        }

        presenter.present(controller, animated: true) {
            if media.startAt > 5 {
                player.seek(to: CMTime(seconds: media.startAt, preferredTimescale: 600))
            }
            player.play()
        }
    }

    /// 服务器返回的错误码对应的提示；不是「拒绝访问 / 地址失效」这类就返回 nil（让播放器自己重试）。
    static func accessErrorMessage(statusCode: Int) -> String? {
        switch statusCode {
        case 401, 403, 451: return "这个视频在你所在的地区不能播放（服务器拒绝访问）"
        case 404, 410: return "视频地址已经失效"
        default: return nil
        }
    }

    /// 翻一遍播放器的错误日志，出现过「拒绝访问 / 地址失效」就返回对应提示。
    static func accessErrorMessage(in item: AVPlayerItem) -> String? {
        #if DEBUG
        for e in item.errorLog()?.events ?? [] {
            NSLog("PLAYERLOG status=%d domain=%@ comment=%@ uri=%@", e.errorStatusCode, e.errorDomain, e.errorComment ?? "", String((e.uri ?? "").prefix(90)))
        }
        if let err = item.error as NSError? {
            NSLog("PLAYERLOG itemError domain=%@ code=%d underlying=%@", err.domain, err.code, String(describing: err.userInfo[NSUnderlyingErrorKey] ?? "nil"))
        }
        #endif
        let events = item.errorLog()?.events ?? []
        // 有版权加密（FairPlay）的视频：要电视台的授权服务器发钥匙，普通播放器播不了，网页全屏也一样
        if events.contains(where: { ($0.errorComment ?? "").contains("streamingkeydelivery") || ($0.errorComment ?? "").contains("KEYFORMAT") }) {
            return "这个视频有版权加密，只能在电视台的官方 App 里看"
        }
        for event in events.reversed() {
            if let message = accessErrorMessage(statusCode: event.errorStatusCode) { return message }
            // 有时错误码是 CoreMedia 自己的（比如 -12938），HTTP 状态码只写在说明里：「HTTP 404: File Not Found」
            if let comment = event.errorComment, let range = comment.range(of: #"HTTP (\d{3})"#, options: .regularExpression),
               let code = Int(comment[range].dropFirst(5)), let message = accessErrorMessage(statusCode: code) {
                return message
            }
        }
        return nil
    }

    /// 自检用：直接关闭播放器。
    func close() {
        finish(.closed)
    }

    private func finish(_ ending: Ending) {
        guard !ended, pendingEnding == nil else { return }
        pendingEnding = ending
        if controller.presentingViewController != nil {
            controller.dismiss(animated: true) { [weak self] in self?.complete() }
        } else {
            complete()
        }
    }

    /// 用户按返回键关掉播放器时，系统会调用这里。
    func playerViewControllerDidEndDismissalTransition(_ playerViewController: AVPlayerViewController) {
        if pendingEnding == nil { pendingEnding = .closed }
        complete()
    }

    private func complete() {
        guard !ended else { return }
        ended = true
        let seconds = player?.currentTime().seconds ?? 0
        player?.pause()
        statusObservation = nil
        watchdog?.invalidate()
        watchdog = nil
        for observer in [endObserver, errorObserver, failObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        switch pendingEnding ?? .closed {
        case .closed: onClose?(seconds.isFinite ? seconds : 0)
        case .next: onNext?()
        case .failed(let message, let tryWeb): onFailure?(message, tryWeb)
        }
    }
}
