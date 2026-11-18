import Foundation

/// CarWithin 连通性探测。
///
/// 为什么需要它：CarWithin 的端口是它自己起的，不是固定协议端口，靠猜很容易一直错。
/// 而且 `ws://` 连不上时 `URLSession` 给的错误很含糊（-1022 ATS、-1004 连不上、
/// -1001 超时、-1011 服务端拒绝），只有把 HTTP 层的结果打出来才知道到底是哪一种。
///
/// 探测做两件事：
///   1. 对候选地址发一个普通 GET，看有没有 HTTP 响应、响应码、以及页面里有没有 CarWithin 字样；
///   2. 对 `/stream` 发不带 Upgrade 的 GET，看服务端怎么回（404 说明路径不对，400/426 说明路径对）。
struct CarWithinProbe {

    struct Result: Identifiable {
        let id = UUID()
        let target: String
        let ok: Bool
        let detail: String
    }

    /// 常见候选端口（CarWithin 默认 http/ws 与 https/wss 成对出现）
    private static let commonPorts = [9888, 9889, 9880, 9881, 8080, 8000, 8888, 9000]

    static func run(rawHost: String) async -> [Result] {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = parse(trimmed)
        let hostOnly = parsed.host

        var candidates: [(String, Int)] = []
        if !hostOnly.isEmpty {
            if let portText = parsed.port, let port = Int(portText) {
                candidates.append((hostOnly, port))
            } else {
                for port in commonPorts { candidates.append((hostOnly, port)) }
            }
        }

        // 同一个手机上的 CarWithin，走回环最稳，不受热点/AP 隔离影响
        for port in commonPorts where !candidates.contains(where: { $0.0 == "127.0.0.1" && $0.1 == port }) {
            candidates.append(("127.0.0.1", port))
        }

        var results: [Result] = []
        await withTaskGroup(of: Result?.self) { group in
            for (host, port) in candidates {
                group.addTask { await probeOne(host: host, port: port) }
            }
            for await r in group {
                if let r { results.append(r) }
            }
        }
        results.sort { $0.target < $1.target }
        return results
    }

    private static func parse(_ text: String) -> (scheme: String?, host: String, port: String?) {
        var s = text
        var scheme: String? = nil
        if let r = s.range(of: "://") {
            scheme = String(s[s.startIndex..<r.lowerBound])
            s = String(s[r.upperBound...])
        }
        // 去掉路径
        if let slash = s.firstIndex(of: "/") {
            s = String(s[s.startIndex..<slash])
        }
        let parts = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            return (scheme, String(parts[0]), String(parts[1]))
        }
        return (scheme, s, nil)
    }

    private static func probeOne(host: String, port: Int) async -> Result? {
        let target = "\(host):\(port)"
        guard let url = URL(string: "http://\(host):\(port)/") else { return nil }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.6
        cfg.timeoutIntervalForResource = 1.6
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data.prefix(4000), encoding: .utf8) ?? ""
            let isCarWithin = body.contains("CarWithin") || body.contains("carwithin")
            let looksLikePage = body.contains("<html") || body.contains("<script") || body.contains("<!DOCTYPE")
            guard isCarWithin || looksLikePage || code == 200 else { return nil }

            // 再探一次 /stream：不带 Upgrade 的 GET 能看到服务端对路径的态度
            var streamNote = ""
            if let sURL = URL(string: "http://\(host):\(port)/stream") {
                if let (sData, sResp) = try? await session.data(from: sURL) {
                    let sCode = (sResp as? HTTPURLResponse)?.statusCode ?? -1
                    let sText = String(data: sData.prefix(160), encoding: .utf8) ?? ""
                    streamNote = " · /stream → \(sCode) \(sText.isEmpty ? "" : "「\(sText.replacingOccurrences(of: "\n", with: " "))」")"
                } else {
                    streamNote = " · /stream → 无响应"
                }
            }

            let tag = isCarWithin ? "CarWithin ✓" : "HTTP 服务"
            return Result(target: target, ok: true,
                          detail: "\(tag) · GET / → \(code) · 页面 \(data.count) 字节\(streamNote)")
        } catch {
            let ns = error as NSError
            // 只报「有意义的失败」：连不上最常见，但也说明端口没开
            if ns.code == -1001 || ns.code == -1004 || ns.code == -1005 {
                return Result(target: target, ok: false,
                              detail: "无响应（\(ns.code)）—— 端口没开或不在同一网段")
            }
            return Result(target: target, ok: false,
                          detail: "失败 \(ns.domain) \(ns.code)：\(ns.localizedDescription)")
        }
    }
}
