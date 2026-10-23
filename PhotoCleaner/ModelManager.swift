import CoreML
import Foundation

/// Resolves the two EmbeddingGemma 2 Core ML packages.
///
/// Debug builds carry the raw .mlpackage files inside the app bundle under
/// `Models/` (copied by a Debug-only Run Script phase from the prototype
/// directory on this Mac). At first launch we compile each package to a
/// .mlmodelc via `MLModel.compileModel(at:)` and cache it in Documents, so
/// subsequent launches skip compilation.
enum ModelManager {

    enum ModelError: LocalizedError {
        case packageMissing(String)

        var errorDescription: String? {
            switch self {
            case .packageMissing(let name):
                return "模型包未随 App 打包：\(name).mlpackage（Debug 构建由脚本注入，Release 需另行分发）"
            }
        }
    }

    /// Returns a compiled-model URL for `package`, compiling on first use.
    static func compiledModelURL(package name: String) throws -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("models-compiled", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let dst = dir.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        if fm.fileExists(atPath: dst.path) {
            AutoTest.log("[ModelManager] \(name): 命中编译缓存")
            return dst
        }
        guard let src = Bundle.main.url(forResource: name, withExtension: "mlpackage", subdirectory: "Models") else {
            throw ModelError.packageMissing(name)
        }
        AutoTest.log("[ModelManager] \(name): 开始编译 mlpackage …")
        let t0 = CFAbsoluteTimeGetCurrent()
        let tmp = try MLModel.compileModel(at: src)
        AutoTest.log("[ModelManager] \(name): 编译完成，耗时 \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - t0))s")
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.moveItem(at: tmp, to: dst)
        return dst
    }

    /// Loads one function of a multifunction .mlpackage.
    static func loadModel(package name: String, function: String, computeUnits: MLComputeUnits = .all) throws -> MLModel {
        let url = try compiledModelURL(package: name)
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        config.functionName = function
        return try MLModel(contentsOf: url, configuration: config)
    }
}
