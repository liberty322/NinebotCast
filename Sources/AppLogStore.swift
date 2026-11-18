import Foundation

/// 对应 NinebotPro 的 `AppLogStore`：环形缓冲 + 一键导出。
///
/// 原版的日志卡能翻、能复制、能导出；投屏出问题时这是唯一能看的证据，
/// 因为仪表黑屏时手机上没有任何反馈。
final class AppLogStore: ObservableObject {

    struct Entry: Identifiable {
        let id = UUID()
        let time: Date
        let text: String
    }

    /// 上限，超过就丢最早的
    private let capacity = 500

    @Published private(set) var entries: [Entry] = []

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ text: String) {
        let entry = Entry(time: Date(), text: text)
        if Thread.isMainThread {
            append(entry)
        } else {
            DispatchQueue.main.async { [weak self] in self?.append(entry) }
        }
    }

    private func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func clear() {
        entries.removeAll()
    }

    /// 导出用纯文本，带时间戳
    var exportText: String {
        let header = "Ninebot Pro+ 诊断日志 · \(AppVersion.display)\n"
        let body = entries.map { "\(formatter.string(from: $0.time))  \($0.text)" }.joined(separator: "\n")
        return header + "----------------------------------------\n" + body + "\n"
    }

    /// 写一个临时文件供 ShareLink 导出
    func exportFileURL() -> URL? {
        let name = "ninebotpro-log-\(Int(Date().timeIntervalSince1970)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try exportText.data(using: .utf8)?.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
