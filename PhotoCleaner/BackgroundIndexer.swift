import BackgroundTasks
import Foundation

/// 后台自动索引：BGProcessingTask（充电时、15 分钟后来电窗口）。
///
/// - 注册在 App init（必须在 applicationDidFinishLaunching 之前完成）
/// - 调度时机：每次启动 + 每次扫描完成后各排下一次
/// - handler 复用现有 LibraryScanner（@MainActor）做主actor驱动，
///   断点续跑由扫描器自带（过期中断直接停，下次接着跑）
/// - 模拟器/调试场景 register/schedule 抛错一律捕获，不 crash
final class BackgroundIndexer: @unchecked Sendable {

    static let shared = BackgroundIndexer()
    static let identifier = "com.ccl125.PhotoCleaner.indexing"

    private weak var scannerBox: WeakScanner?
    private let lock = NSLock()

    private final class WeakScanner { weak var value: LibraryScanner? }

    private init() {}

    /// App init 时注入共享 scanner（StateObject 的 wrappedValue）。
    func configure(scanner: LibraryScanner) {
        let box = WeakScanner()
        box.value = scanner
        lock.lock()
        scannerBox = box
        lock.unlock()
    }

    private var scanner: LibraryScanner? {
        lock.lock()
        defer { lock.unlock() }
        return scannerBox?.value
    }

    // MARK: - 注册与调度

    /// 必须在 App 启动早期调用。
    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            self.handle(task)
        }
        AutoTest.log("[BGTask] 已注册 \(Self.identifier)")
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "backgroundIndexEnabled") as? Bool ?? true
    }

    /// 排下一次任务（先取消旧的再排，重复调度会抛错故吞掉）。
    func scheduleNextIfEnabled() {
        guard Self.isEnabled else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        let request = BGProcessingTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        request.requiresExternalPower = true       // 充电时才跑
        request.requiresNetworkConnectivity = false // iCloud 拉图走按需，不做硬依赖
        do {
            try BGTaskScheduler.shared.submit(request)
            AutoTest.log("[BGTask] 已调度下一次后台索引（15 分钟后、充电时）")
        } catch {
            AutoTest.log("[BGTask] 调度失败（模拟器/调试场景可忽略）: \(error.localizedDescription)")
        }
    }

    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        AutoTest.log("[BGTask] 已取消调度（开关关闭）")
    }

    // MARK: - 任务处理

    private func handle(_ task: BGProcessingTask) {
        AutoTest.log("[BGTask] 后台任务启动")
        scheduleNextIfEnabled()  // 先排下一次，保证链式不断

        let state = TaskState()
        task.expirationHandler = {
            AutoTest.log("[BGTask] 系统时间到期，中断扫描（进度已落库，下次续跑）")
            state.markExpired()
            if let scanner = self.scanner {
                Task { @MainActor in scanner.pause() }
            }
        }

        Task { @MainActor in
            guard let scanner = self.scanner else {
                state.finish(task, success: false)
                return
            }
            scanner.refreshAuth()
            scanner.refreshCounts()
            guard scanner.authStatus == .authorized || scanner.authStatus == .limited else {
                AutoTest.log("[BGTask] 无相册权限，退出")
                state.finish(task, success: false)
                return
            }

            // 先查 pending：没活就立刻完成，不浪费系统配额
            let store = scanner.store
            try? store.open()
            let indexed = store.count()
            let missingVectors = scanner.totalAssets - indexed
            let ocrMissing = indexed - store.ocrCoverage().total
            let qualityMissing = indexed - store.existingQualityIDs().count
            let pending = max(missingVectors, max(ocrMissing, qualityMissing))
            guard pending > 0 else {
                AutoTest.log("[BGTask] 无待处理条目，直接完成")
                state.finish(task, success: true)
                return
            }

            AutoTest.log("[BGTask] 开始增量扫描，约 \(pending) 条待处理")
            scanner.start()
            while scanner.isBusy && !state.isExpired {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            guard !state.isExpired else {
                state.finish(task, success: false)
                return
            }

            AutoTest.log("[BGTask] 扫描完成（已索引 \(scanner.indexedCount) 张），开始分析")
            await AnalysisService.shared.analyze(scanner: scanner)
            AutoTest.log("[BGTask] 后台任务完成")
            state.finish(task, success: true)
        }
    }

    /// 过期/完成状态（expirationHandler 在任意线程触发，统一加锁）。
    private final class TaskState: @unchecked Sendable {
        private let lock = NSLock()
        private var expired = false
        private var completed = false

        var isExpired: Bool {
            lock.lock()
            defer { lock.unlock() }
            return expired
        }

        func markExpired() {
            lock.lock()
            expired = true
            lock.unlock()
        }

        /// setTaskCompleted 只能调一次。
        func finish(_ task: BGTask, success: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return }
            completed = true
            task.setTaskCompleted(success: success)
        }
    }
}
