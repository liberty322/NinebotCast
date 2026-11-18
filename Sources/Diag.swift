import Foundation

/// 极简文件日志。
///
/// 为什么需要它：免费签名装的 App 闪退后，手机上看不到崩溃日志，我也拿不到。
/// 所以把「启动 / 开播 / 编码器创建 / 首帧 / 首包 / 停止」这些阶段节点写进
/// Documents/cast-diag.log，下次打开 App 时直接显示在「诊断」区里。
///
/// v1.0.2 起加了一个 sink：同一行日志同时喂给界面的日志面板。
/// 之前只有文件有这些内容，导出的日志里看不到 CarWithin 内部发生了什么，
/// 出问题时等于抓瞎。
enum Diag {
    private static let lock = NSLock()
    private static let fileName = "cast-diag.log"
    private static let maxBytes = 256 * 1024

    /// 界面日志面板的落点（AppLogStore.log）。在锁外调用，避免互相递归卡死。
    static var sink: ((String) -> Void)?

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent(fileName)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        let line = "[\(stampFormatter.string(from: Date()))] \(message)\n"
        writeToFile(line)
        sink?(message)
    }

    private static func writeToFile(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        let url = fileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
        trimIfNeededLocked(url)
        lock.unlock()
    }

    private static func trimIfNeededLocked(_ url: URL) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? Int) ?? 0
        guard bytes > maxBytes else { return }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let keep = content.split(separator: "\n").suffix(160).joined(separator: "\n")
        try? (keep + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// 读取最后若干行，给界面显示
    static func tail(_ lineCount: Int = 16) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8),
              !content.isEmpty else {
            return "（暂无日志）"
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(lineCount).joined(separator: "\n")
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 启动时调用：打一条启动记录，并挂上未捕获异常处理器（NSException 能落盘）
    static func installCrashHandler(version: String) {
        log("======== APP LAUNCH \(version) ========")
        NSSetUncaughtExceptionHandler { exception in
            Diag.log("CRASH EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "-")")
            let stack = exception.callStackSymbols.prefix(10).joined(separator: " || ")
            Diag.log("CRASH STACK \(stack)")
        }
    }
}
