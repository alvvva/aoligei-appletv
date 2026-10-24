import Foundation

/// 内置起始页：一个大搜索框加收藏的网站格子。
/// 起始页上的按钮用 tvbrowser:// 链接，由 App 接管处理。
enum StartPage {
    /// 起始页上「最近看过」最多显示几条。
    static let recentLimit = 12

    private static let palette = ["#e5534b", "#f0883e", "#d4a72c", "#57ab5a", "#39c5cf", "#539bf5", "#986ee2", "#e275ad"]

    private static func color(for host: String) -> String {
        palette[abs(host.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count]
    }

    private static func shortHost(_ url: String) -> String {
        let host = URL(string: url)?.host ?? url
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// 「刚刚」「5 分钟前」「3 小时前」「昨天」「10月20日」
    static func relativeTime(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600)) 小时前" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天"
        }
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f.string(from: date)
    }

    static func html(bookmarks: [Bookmark], recent: [HistoryItem] = [], live: [SiteRules.LiveChannel] = SiteRules.liveChannels,
                     engineName: String, now: Date = Date()) -> String {
        let tiles = bookmarks.prefix(30).map { b -> String in
            let host = URL(string: b.url)?.host ?? b.url
            let shortHost = shortHost(b.url)
            let letter = b.title.first.map { String($0).uppercased() } ?? "?"
            let color = color(for: host)
            return """
            <a class="tile" href="\(escape(b.url))">
              <div class="icon" style="background:\(color)">\(escape(letter))</div>
              <div class="name">\(escape(b.title))</div>
              <div class="host">\(escape(shortHost))</div>
            </a>
            """
        }.joined(separator: "\n")

        let emptyHint = bookmarks.isEmpty
            ? "<p class=\"hint\">还没有收藏。打开网页后长按触控板，选择「收藏本页」。</p>"
            : ""

        let liveTiles = live.map { ch -> String in
            let host = URL(string: ch.url)?.host ?? ch.url
            let letter = ch.name.first.map { String($0).uppercased() } ?? "?"
            return """
            <a class="tile live-tile" href="\(escape(ch.url))">
              <div class="badge">● 直播</div>
              <div class="icon" style="background:\(color(for: host))">\(escape(letter))</div>
              <div class="name">\(escape(ch.name))</div>
              <div class="host">\(escape(ch.note))</div>
            </a>
            """
        }.joined(separator: "\n")
        let liveSection = live.isEmpty ? "" : """
          <h2 class="section">直播</h2>
          <div class="grid">
          \(liveTiles)
          </div>
        """

        let recentRows = recent.prefix(recentLimit).map { item -> String in
            let host = URL(string: item.url)?.host ?? item.url
            let letter = (item.title.first ?? shortHost(item.url).first).map { String($0).uppercased() } ?? "?"
            return """
            <a class="row" href="\(escape(item.url))">
              <div class="dot" style="background:\(color(for: host))">\(escape(letter))</div>
              <div class="info"><div class="title">\(escape(item.title))</div>
              <div class="meta">\(escape(shortHost(item.url))) · \(escape(relativeTime(item.date, now: now)))</div></div>
            </a>
            """
        }.joined(separator: "\n")
        let recentSection = recent.isEmpty ? "" : """
          <div class="recent-head"><h2>最近看过</h2>
            <a href="tvbrowser://history">全部历史</a><a href="tvbrowser://clear-history">清空</a></div>
          <div class="recent">
          \(recentRows)
          </div>
        """

        return """
        <!doctype html>
        <html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>起始页</title>
        <style>
          * { box-sizing: border-box; }
          html, body { margin: 0; background: #0d1117; color: #e6edf3;
            font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif; }
          main { padding: 70px 110px 80px; }
          h1 { font-size: 56px; font-weight: 700; margin: 0 0 36px; letter-spacing: 1px; }
          .search { display: flex; align-items: center; gap: 24px; text-decoration: none;
            background: #161b22; border: 3px solid #30363d; border-radius: 28px;
            padding: 30px 40px; color: #8b949e; font-size: 36px; margin-bottom: 56px; }
          .search .glass { font-size: 40px; }
          h2 { font-size: 32px; font-weight: 600; color: #8b949e; margin: 0 0 24px; }
          .grid { display: grid; grid-template-columns: repeat(6, 1fr); gap: 28px; }
          .tile { display: flex; flex-direction: column; align-items: center; text-decoration: none;
            background: #161b22; border: 3px solid #21262d; border-radius: 24px; padding: 32px 16px 26px;
            color: #e6edf3; min-width: 0; }
          .icon { width: 104px; height: 104px; border-radius: 26px; display: flex; align-items: center;
            justify-content: center; font-size: 52px; font-weight: 700; color: #fff; margin-bottom: 20px; }
          .name { font-size: 28px; font-weight: 600; max-width: 100%; overflow: hidden;
            text-overflow: ellipsis; white-space: nowrap; }
          .host { font-size: 22px; color: #8b949e; margin-top: 6px; max-width: 100%; overflow: hidden;
            text-overflow: ellipsis; white-space: nowrap; }
          .links { display: flex; gap: 24px; margin-top: 56px; }
          .links a { text-decoration: none; color: #e6edf3; background: #21262d; border-radius: 18px;
            padding: 20px 34px; font-size: 28px; }
          .hint { font-size: 28px; color: #8b949e; }
          .section { margin-top: 56px; }
          .live-tile { position: relative; padding-top: 62px; }
          .badge { position: absolute; top: 14px; right: 14px; background: #e5534b; color: #fff; font-size: 20px;
            font-weight: 700; padding: 4px 12px; border-radius: 10px; }
          .recent-head { display: flex; align-items: baseline; gap: 28px; margin-top: 56px; }
          .recent-head h2 { margin: 0 0 24px; }
          .recent-head a { font-size: 26px; color: #539bf5; text-decoration: none; }
          .recent { display: grid; grid-template-columns: repeat(2, 1fr); gap: 20px 28px; }
          .row { display: flex; align-items: center; gap: 24px; text-decoration: none; color: #e6edf3;
            background: #161b22; border: 3px solid #21262d; border-radius: 20px; padding: 20px 26px; min-width: 0; }
          .dot { flex: none; width: 64px; height: 64px; border-radius: 16px; display: flex; align-items: center;
            justify-content: center; font-size: 32px; font-weight: 700; color: #fff; }
          .info { min-width: 0; }
          .title { font-size: 28px; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .meta { font-size: 22px; color: #8b949e; margin-top: 6px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        </style></head>
        <body><main>
          <h1>奥利给</h1>
          <a class="search" href="tvbrowser://search"><span class="glass">🔍</span>
            <span>输入网址，或用 \(escape(engineName)) 搜索</span></a>
          <h2>收藏</h2>
          <div class="grid">
          \(tiles)
          </div>
          \(emptyHint)
          \(liveSection)
          \(recentSection)
          <div class="links">
            <a href="tvbrowser://bookmarks">管理收藏</a>
            <a href="tvbrowser://history">历史记录</a>
            <a href="tvbrowser://menu">菜单与设置</a>
            <a href="tvbrowser://help">遥控器操作说明</a>
          </div>
        </main></body></html>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
