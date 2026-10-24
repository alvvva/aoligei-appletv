import Foundation

struct Bookmark: Codable, Equatable {
    var title: String
    var url: String
}

struct HistoryItem: Codable {
    var title: String
    var url: String
    var date: Date
}

/// 用 UserDefaults 保存设置、收藏和历史记录。
final class Store {
    static let shared = Store()

    private let defaults: UserDefaults
    private let maxHistory = 200

    private enum Key {
        static let homepage = "homepage"
        static let searchEngine = "searchEngine"
        static let bookmarks = "bookmarks"
        static let history = "history"
        static let cursorSpeed = "cursorSpeedV2"
        static let adBlock = "adBlockEnabled"
        static let autoFullscreen = "autoFullscreenVideo"
        static let siteZoom = "siteZoom"
        static let desktopMode = "desktopMode"
        static let pageZoom = "pageZoom"
        static let showTopBar = "showTopBar"
        static let lastURL = "lastURL"
        static let hasSeenHelp = "hasSeenHelp"
        static let seeded = "seededBookmarks"
        static let bookmarkDefaultsVersion = "bookmarkDefaultsVersion"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.homepage: "",
            Key.searchEngine: SearchEngine.google.rawValue,
            Key.cursorSpeed: Store.defaultCursorSpeed,
            Key.adBlock: true,
            Key.autoFullscreen: false,
            Key.desktopMode: true,
            Key.pageZoom: 1.0,
            Key.showTopBar: true,
        ])
        if !defaults.bool(forKey: Key.seeded) {
            defaults.set(true, forKey: Key.seeded)
            bookmarks = Store.defaultBookmarks
        } else {
            // 已经装过的 App：把之后版本新增的默认网站补进收藏，已有的不重复添加
            let installed = defaults.integer(forKey: Key.bookmarkDefaultsVersion)
            if installed < 2 {
                let missing = Store.addedInVersion2.filter { !isBookmarked($0.url) }
                bookmarks = missing + bookmarks
            }
            if installed < 3 {
                // 夜視影音排在欧乐、酷播后面
                var list = bookmarks
                let missing = Store.addedInVersion3.filter { !isBookmarked($0.url) }
                let anchor = list.lastIndex { item in Store.addedInVersion2.contains { $0.url == item.url } }
                let position = anchor.map { $0 + 1 } ?? 0
                list.insert(contentsOf: missing, at: position)
                bookmarks = list
            }
        }
        defaults.set(Store.bookmarkDefaultsVersion, forKey: Key.bookmarkDefaultsVersion)
    }

    /// 默认收藏每次增加网站时加 1，已安装的 App 会在下次启动时补上新增的网站。
    /// 补过一次之后，用户删掉的默认网站不会再被加回来。
    static let bookmarkDefaultsVersion = 3

    /// 第 2 版新增的默认网站。
    static let addedInVersion2: [Bookmark] = [
        Bookmark(title: "欧乐影院", url: "https://www.olehdtv.com"),
        Bookmark(title: "酷播", url: "https://www.kubb.tv"),
    ]

    /// 第 3 版新增的默认网站（直播）。
    static let addedInVersion3: [Bookmark] = [
        Bookmark(title: "夜視影音", url: "https://yeslivetv.com"),
    ]

    static let defaultBookmarks: [Bookmark] = addedInVersion2 + addedInVersion3 + [
        Bookmark(title: "Google", url: "https://www.google.com"),
        Bookmark(title: "YouTube", url: "https://www.youtube.com"),
        Bookmark(title: "哔哩哔哩", url: "https://www.bilibili.com"),
        Bookmark(title: "百度", url: "https://www.baidu.com"),
        Bookmark(title: "维基百科", url: "https://zh.wikipedia.org"),
        Bookmark(title: "Bing", url: "https://www.bing.com"),
    ]

    /// 空字符串表示用内置起始页。
    var homepage: String {
        get { defaults.string(forKey: Key.homepage) ?? "" }
        set { defaults.set(newValue, forKey: Key.homepage) }
    }

    var searchEngine: SearchEngine {
        get { SearchEngine(rawValue: defaults.string(forKey: Key.searchEngine) ?? "") ?? .google }
        set { defaults.set(newValue.rawValue, forKey: Key.searchEngine) }
    }

    /// 光标速度档位：慢 / 中 / 快。
    static let cursorSpeeds: [(name: String, value: Double)] = [("慢", 0.6), ("中", 0.85), ("快", 1.2)]
    static let defaultCursorSpeed = 0.85

    /// 内置的网站缩放比例。Apple TV 的网页引擎放大时不会重新排版，放大的页面会超出屏幕，
    /// 所以欧乐和酷播都保持 100%（它们的电脑版在 1920 宽的电视上正好铺满）。
    static let builtInSiteZoom: [String: Double] = [:]

    var cursorSpeed: Double {
        get { defaults.double(forKey: Key.cursorSpeed) }
        set { defaults.set(newValue, forKey: Key.cursorSpeed) }
    }

    var adBlockEnabled: Bool {
        get { defaults.bool(forKey: Key.adBlock) }
        set { defaults.set(newValue, forKey: Key.adBlock) }
    }

    /// 网页里的视频开始播放时，自动用原生播放器全屏播放。
    var autoFullscreen: Bool {
        get { defaults.bool(forKey: Key.autoFullscreen) }
        set { defaults.set(newValue, forKey: Key.autoFullscreen) }
    }

    /// 某个网站的缩放比例：用户设过的优先，其次是内置比例，最后是全局比例。
    func zoom(forHost host: String?) -> Double {
        guard let site = Store.siteKey(host) else { return pageZoom }
        let saved = defaults.dictionary(forKey: Key.siteZoom) as? [String: Double] ?? [:]
        return saved[site] ?? Store.builtInSiteZoom[site] ?? pageZoom
    }

    func setZoom(_ zoom: Double, forHost host: String?) {
        guard let site = Store.siteKey(host) else { pageZoom = zoom; return }
        var saved = defaults.dictionary(forKey: Key.siteZoom) as? [String: Double] ?? [:]
        saved[site] = zoom
        defaults.set(saved, forKey: Key.siteZoom)
    }

    /// 网站的主域名，例如 www.kubb.tv → kubb.tv。
    static func siteKey(_ host: String?) -> String? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        let parts = host.split(separator: ".")
        return parts.count <= 2 ? host : parts.suffix(2).joined(separator: ".")
    }

    var desktopMode: Bool {
        get { defaults.bool(forKey: Key.desktopMode) }
        set { defaults.set(newValue, forKey: Key.desktopMode) }
    }

    var pageZoom: Double {
        get { defaults.double(forKey: Key.pageZoom) }
        set { defaults.set(newValue, forKey: Key.pageZoom) }
    }

    var showTopBar: Bool {
        get { defaults.bool(forKey: Key.showTopBar) }
        set { defaults.set(newValue, forKey: Key.showTopBar) }
    }

    var lastURL: String? {
        get { defaults.string(forKey: Key.lastURL) }
        set { defaults.set(newValue, forKey: Key.lastURL) }
    }

    var hasSeenHelp: Bool {
        get { defaults.bool(forKey: Key.hasSeenHelp) }
        set { defaults.set(newValue, forKey: Key.hasSeenHelp) }
    }

    var bookmarks: [Bookmark] {
        get { decode([Bookmark].self, forKey: Key.bookmarks) ?? [] }
        set { encode(newValue, forKey: Key.bookmarks) }
    }

    var history: [HistoryItem] {
        get { decode([HistoryItem].self, forKey: Key.history) ?? [] }
        set { encode(Array(newValue.prefix(maxHistory)), forKey: Key.history) }
    }

    func isBookmarked(_ url: String) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    /// 返回 false 表示已经收藏过。
    @discardableResult
    func addBookmark(title: String, url: String) -> Bool {
        guard !isBookmarked(url) else { return false }
        bookmarks.append(Bookmark(title: title.isEmpty ? url : title, url: url))
        return true
    }

    func removeBookmark(url: String) {
        bookmarks.removeAll { $0.url == url }
    }

    /// 最新的在最前面；同一网址只保留最近一次。
    func recordVisit(title: String, url: String) {
        var items = history
        items.removeAll { $0.url == url }
        items.insert(HistoryItem(title: title.isEmpty ? url : title, url: url, date: Date()), at: 0)
        history = items
    }

    /// 页面标题晚于加载完成才出现时，把历史里用网址代替的标题补上。
    func updateHistoryTitle(_ title: String, for url: String) {
        guard !title.isEmpty else { return }
        var items = history
        guard let i = items.firstIndex(where: { $0.url == url }), items[i].title != title else { return }
        items[i].title = title
        history = items
    }

    func clearHistory() {
        history = []
    }

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
