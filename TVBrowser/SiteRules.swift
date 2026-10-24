import Foundation

/// 按网站做的特殊处理。
enum SiteRules {
    /// 要用手机版网页打开的页面：(网站主域名, 路径前缀)。
    /// 小红书直播间：电脑版给的是 FLV 格式，Apple TV 播不了；手机版给的是 HLS（m3u8），原生播放器能直接全屏播放。
    static let mobileOnly: [(site: String, pathPrefix: String)] = [
        ("xiaohongshu.com", "/livestream/"),
    ]

    static func prefersMobile(_ url: URL) -> Bool {
        guard let site = Store.siteKey(url.host) else { return false }
        return mobileOnly.contains { site == $0.site && url.path.hasPrefix($0.pathPrefix) }
    }

    /// 起始页「直播」专区：在爱尔兰实测能看的官方免费直播。
    struct LiveChannel {
        let name: String
        let note: String
        let url: String
    }

    static let liveChannels: [LiveChannel] = [
        LiveChannel(name: "CGTN", note: "中国国际电视台 · 英语", url: "https://www.cgtn.com/tv"),
        LiveChannel(name: "小红书直播", note: "挑一个直播间进去看", url: "https://www.xiaohongshu.com/livelist"),
        LiveChannel(name: "NHK World", note: "日本 · 英语", url: "https://www3.nhk.or.jp/nhkworld/en/live/"),
        LiveChannel(name: "DW", note: "德国之声 · 英语", url: "https://www.dw.com/en/live-tv/channel-english"),
        LiveChannel(name: "半岛电视台", note: "Al Jazeera · 英语", url: "https://www.aljazeera.com/live"),
        LiveChannel(name: "Euronews", note: "欧洲新闻 · 英语", url: "https://www.euronews.com/live"),
    ]
}
