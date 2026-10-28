import Foundation

/// 自测模式（-autoTest）支持：日志同时写 stdout 和 Documents/autotest.log，
/// 便于通过 devicectl 从设备拉回日志做无人值守验证。
enum AutoTest {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-autoTest")

    static let logURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("autotest.log")

    /// 静态共享（原来每行新建一个，格式化器很贵）
    private static let formatter = ISO8601DateFormatter()

    static func log(_ s: String) {
        print(s)
        // 始终写文件，便于真机问题诊断（不仅仅是自测模式）
        let line = "\(formatter.string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    static func resetLog() {
        guard enabled else { return }
        // 无界增长保护：超过 5MB 截断只保留尾部 ~2MB
        if let data = try? Data(contentsOf: logURL), data.count > 5 * 1024 * 1024 {
            let tail = data.suffix(2 * 1024 * 1024)
            try? tail.write(to: logURL, options: .atomic)
            return
        }
        try? FileManager.default.removeItem(at: logURL)
    }
}
