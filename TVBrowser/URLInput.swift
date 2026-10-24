import Foundation

/// 搜索引擎。
enum SearchEngine: String, CaseIterable, Codable {
    case google, bing, baidu, duckduckgo

    var displayName: String {
        switch self {
        case .google: return "Google"
        case .bing: return "Bing 必应"
        case .baidu: return "百度"
        case .duckduckgo: return "DuckDuckGo"
        }
    }

    func searchURL(for query: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        switch self {
        case .google: return URL(string: "https://www.google.com/search?q=\(q)")
        case .bing: return URL(string: "https://www.bing.com/search?q=\(q)")
        case .baidu: return URL(string: "https://www.baidu.com/s?wd=\(q)")
        case .duckduckgo: return URL(string: "https://duckduckgo.com/?q=\(q)")
        }
    }
}

/// 把用户在地址栏里输入的文字变成要打开的网址：像网址的直接打开，否则当作搜索词。
enum URLInput {
    static func url(for raw: String, engine: SearchEngine) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: text) ?? engine.searchURL(for: text)
        }
        if text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            if lower.hasPrefix("about:") {
                return URL(string: text)
            }
            if let host = hostPart(of: text) {
                if isLocalOrIP(host) {
                    return URL(string: "http://" + text)
                }
                if looksLikeDomain(host) {
                    return URL(string: "https://" + text)
                }
            }
        }
        return engine.searchURL(for: text)
    }

    /// 取出“域名:端口/路径”里的域名部分。
    static func hostPart(of text: String) -> String? {
        let beforePath = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        let beforeQuery = beforePath.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? beforePath
        let host = beforeQuery.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? beforeQuery
        return host.isEmpty ? nil : host.lowercased()
    }

    static func isLocalOrIP(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard let n = Int(part), part.allSatisfy(\.isNumber) else { return false }
            return (0...255).contains(n)
        }
    }

    static func looksLikeDomain(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        guard let tld = labels.last, tld.count >= 2 else { return false }
        // 顶级域名必须是字母（也允许中文域名，如 .中国）
        return tld.allSatisfy { $0.isLetter } && labels.allSatisfy { label in
            label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}
