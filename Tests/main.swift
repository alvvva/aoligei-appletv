import Foundation

var failures = 0
func check(_ input: String, _ expected: String?, line: Int = #line) {
    let got = URLInput.url(for: input, engine: .google)?.absoluteString
    if got != expected {
        failures += 1
        print("FAIL [\(input)] got=\(got ?? "nil") expected=\(expected ?? "nil")")
    } else {
        print("ok   [\(input)] -> \(got ?? "nil")")
    }
}

check("bilibili.com", "https://bilibili.com")
check("www.youtube.com/watch?v=abc", "https://www.youtube.com/watch?v=abc")
check("https://example.com/a b", "https://example.com/a%20b")
check("http://192.168.1.10:8096", "http://192.168.1.10:8096")
check("192.168.1.10:8096", "http://192.168.1.10:8096")
check("localhost:3000/x", "http://localhost:3000/x")
check("nas.local", "http://nas.local")
check("  apple.com  ", "https://apple.com")
check("天气 都柏林", "https://www.google.com/search?q=%E5%A4%A9%E6%B0%94%20%E9%83%BD%E6%9F%8F%E6%9E%97")
check("百度", "https://www.google.com/search?q=%E7%99%BE%E5%BA%A6")
check("3.14", "https://www.google.com/search?q=3.14")
check("c++ & rust", "https://www.google.com/search?q=c%2B%2B%20%26%20rust")
check("hello", "https://www.google.com/search?q=hello")
check("", nil)
check("about:blank", "about:blank")
check("例子.中国", "https://xn--fsqu00a.xn--fiqs8s")
print(SearchEngine.baidu.searchURL(for: "猫")!.absoluteString)

// 起始页：标题里的特殊字符要被转义
let html = StartPage.html(bookmarks: [Bookmark(title: "<b>A&B\"</b>", url: "https://x.com/?a=1&b=2")], engineName: "Google")
if html.contains("<b>A&B") || !html.contains("&lt;b&gt;A&amp;B&quot;&lt;/b&gt;") || !html.contains("href=\"https://x.com/?a=1&amp;b=2\"") {
    failures += 1; print("FAIL start page escaping")
} else { print("ok   start page escaping") }

// 默认收藏：全新安装、老版本升级、不重复、删掉后不再补回
func freshDefaults(_ name: String) -> UserDefaults {
    let d = UserDefaults(suiteName: "tvbrowser.test.\(name)")!
    d.removePersistentDomain(forName: "tvbrowser.test.\(name)")
    return d
}
func expect(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { print("ok   \(name)") } else { failures += 1; print("FAIL \(name) \(detail)") }
}
do {
    let fresh = Store(defaults: freshDefaults("fresh")).bookmarks.map(\.title)
    expect("全新安装：9 个默认收藏，欧乐、酷播、夜視影音排在最前", fresh.count == 9 && Array(fresh.prefix(3)) == ["欧乐影院", "酷播", "夜視影音"], "\(fresh)")

    // 第 1 版用户：只有 6 个老收藏和自己加的一个
    let v1 = freshDefaults("v1")
    v1.set(true, forKey: "seededBookmarks")
    let v1List = Array(Store.defaultBookmarks.dropFirst(3)) + [Bookmark(title: "我的网站", url: "https://example.com")]
    v1.set(try! JSONEncoder().encode(v1List), forKey: "bookmarks")
    let fromV1 = Store(defaults: v1).bookmarks.map(\.title)
    expect("第 1 版升级：补上三个新网站，原有收藏保留", fromV1.count == 10 && Array(fromV1.prefix(3)) == ["欧乐影院", "酷播", "夜視影音"] && fromV1.last == "我的网站", "\(fromV1)")

    // 第 2 版用户（就是你现在电视上的状态）：欧乐、酷播已经在了
    let v2 = freshDefaults("v2")
    v2.set(true, forKey: "seededBookmarks")
    v2.set(2, forKey: "bookmarkDefaultsVersion")
    let v2List = Store.addedInVersion2 + Array(Store.defaultBookmarks.dropFirst(3)) + [Bookmark(title: "我的网站", url: "https://example.com")]
    v2.set(try! JSONEncoder().encode(v2List), forKey: "bookmarks")
    let fromV2 = Store(defaults: v2).bookmarks.map(\.title)
    expect("第 2 版升级：夜視影音插在欧乐、酷播后面", fromV2.count == 10 && Array(fromV2.prefix(4)) == ["欧乐影院", "酷播", "夜視影音", "Google"], "\(fromV2)")

    let partial = freshDefaults("partial")
    partial.set(true, forKey: "seededBookmarks")
    partial.set(try! JSONEncoder().encode([Bookmark(title: "酷播", url: "https://www.kubb.tv")]), forKey: "bookmarks")
    let partialList = Store(defaults: partial).bookmarks.map(\.url)
    expect("已收藏过的网站不重复添加", partialList == ["https://www.olehdtv.com", "https://www.kubb.tv", "https://yeslivetv.com"], "\(partialList)")

    let store = Store(defaults: v2)
    store.removeBookmark(url: "https://yeslivetv.com")
    let again = Store(defaults: v2).bookmarks.map(\.url)
    expect("补过一次后，用户删掉的默认网站不会再被加回来", !again.contains("https://yeslivetv.com") && again.count == 9, "\(again)")
}

// 起始页「最近看过」
do {
    let now = Date()
    expect("时间：刚刚", StartPage.relativeTime(now.addingTimeInterval(-10), now: now) == "刚刚")
    expect("时间：分钟前", StartPage.relativeTime(now.addingTimeInterval(-300), now: now) == "5 分钟前")
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
    expect("时间：昨天", StartPage.relativeTime(yesterday, now: now) == "昨天")
    let items = (0..<20).map { HistoryItem(title: "第\($0)集 <b>&", url: "https://www.example.com/p/\($0)", date: now.addingTimeInterval(Double(-$0 * 60))) }
    let page = StartPage.html(bookmarks: [], recent: items, engineName: "Google", now: now)
    let rows = page.components(separatedBy: "class=\"row\"").count - 1
    expect("最近看过最多显示 12 条", rows == 12, "rows=\(rows)")
    expect("最近看过：标题被转义、显示网站名", page.contains("第0集 &lt;b&gt;&amp;") && !page.contains("第0集 <b>") && page.contains("example.com · 刚刚"))
    let none = StartPage.html(bookmarks: [], recent: [], engineName: "Google", now: now)
    expect("没有历史时不显示「最近看过」", !none.contains("最近看过"))
}

// 直播专区和小红书直播间换手机版
do {
    let page = StartPage.html(bookmarks: [], engineName: "Google")
    let liveCount = page.components(separatedBy: "class=\"tile live-tile\"").count - 1
    expect("起始页有「直播」专区，频道数正确", page.contains(">直播</h2>") && liveCount == SiteRules.liveChannels.count, "count=\(liveCount)")
    expect("小红书直播间用手机版", SiteRules.prefersMobile(URL(string: "https://www.xiaohongshu.com/livestream/570510767758276437?x=1")!))
    expect("小红书直播列表和其他页面不强制手机版", !SiteRules.prefersMobile(URL(string: "https://www.xiaohongshu.com/livelist")!) && !SiteRules.prefersMobile(URL(string: "https://www.kubb.tv/livestream/1")!))
}

// 把脚本写出来给浏览器测试用（坐标用标记值，测试时替换）
let scripts: [String: String] = [
    "click": PageScripts.click(x: 11111, y: 22222, viewWidth: 33333),
    "setText": PageScripts.setText("你好 \"quote\" \\ </script>", submit: true),
    "select": PageScripts.selectOption(2),
    "scroll": PageScripts.scrollInner(x: 11111, y: 22222, viewWidth: 33333, dx: 0, dy: 120),
    "startPage": StartPage.html(bookmarks: Store.defaultBookmarks, engineName: "Google"),
]
let data = try! JSONSerialization.data(withJSONObject: scripts, options: [.prettyPrinted])
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
