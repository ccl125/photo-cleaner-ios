import Foundation

/// 自测模式（-autoTest）支持：日志同时写 stdout 和 Documents/autotest.log，
/// 便于通过 devicectl 从设备拉回日志做无人值守验证。
enum AutoTest {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-autoTest")

    static let logURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("autotest.log")

    static func log(_ s: String) {
        print(s)
        // 始终写文件，便于真机问题诊断（不仅仅是自测模式）
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
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
        try? FileManager.default.removeItem(at: logURL)
    }
}
