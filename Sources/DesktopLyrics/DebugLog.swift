import Foundation

/// 简易调试日志：写到 ~/Library/Logs/DesktopLyrics.log（每次启动清空）
enum DebugLog {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DesktopLyrics.log")

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let handle: FileHandle? = {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        fm.createFile(atPath: url.path, contents: nil) // 清空旧日志
        return try? FileHandle(forWritingTo: url)
    }()

    static func log(_ message: String) {
        NSLog("%@", message)
        let line = "\(formatter.string(from: Date())) \(message)\n"
        if let data = line.data(using: .utf8) {
            handle?.write(data)
        }
    }
}
