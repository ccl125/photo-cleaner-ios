import Foundation
import Photos
import UIKit

/// PhotoKit 扫描器：拉取最近 6 个月的图片，逐张算 embedding 存入 SQLite。
/// 支持断点续跑（重启后跳过已索引项）与暂停/继续。
@MainActor
final class LibraryScanner: ObservableObject {

    enum State: Equatable {
        case idle
        case preparingModels
        case running
        case paused
        case finished
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var authStatus: PHAuthorizationStatus = .notDetermined
    @Published private(set) var totalAssets = 0      // 最近 6 个月图片总数
    @Published private(set) var indexedCount = 0     // 库里已存向量数（含历史）
    @Published private(set) var processedThisRun = 0
    @Published private(set) var failedThisRun = 0
    @Published private(set) var lastImageMs: Double = 0
    @Published private(set) var avgMs: Double = 0
    /// 自测模式（-autoTest）状态文本，展示在首页供 UI 测试读取。
    @Published var autoTestStatus: String = ""

    let engine = EmbeddingEngine()
    let store = EmbeddingStore()

    private var scanTask: Task<Void, Never>?
    private var pauseRequested = false
    private var pendingTotal = 0

    var isBusy: Bool { state == .running || state == .preparingModels }

    var progress: Double {
        guard pendingTotal > 0 else { return 0 }
        return min(1, Double(processedThisRun + failedThisRun) / Double(pendingTotal))
    }

    // MARK: - 权限

    func refreshAuth() {
        authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// 首页展示用的真实计数：相册最近 6 个月图片总数 + 向量库已索引数。
    /// 不依赖扫描状态（避免上次小范围测试残留的 200 误导显示）。
    func refreshCounts() {
        guard authStatus == .authorized || authStatus == .limited else { return }
        let opts = PHFetchOptions()
        let since = Calendar.current.date(byAdding: .month, value: -6, to: Date())! as NSDate
        opts.predicate = NSPredicate(format: "creationDate > %@", since)
        totalAssets = PHAsset.fetchAssets(with: .image, options: opts).count
        if let opened = try? store.open() {
            _ = opened
            indexedCount = store.count()
        }
    }

    func requestAccess() async {
        authStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: - 扫描控制

    func start() {
        beginScan(limit: nil)
    }

    /// 小范围试运行：只处理最新的 limit 张，用于真机速度验证。
    func startTest(limit: Int = 200) {
        beginScan(limit: limit)
    }

    private func beginScan(limit: Int?) {
        guard !isBusy else { return }
        guard authStatus == .authorized || authStatus == .limited else { return }
        pauseRequested = false
        scanTask = Task { await self.runScan(limit: limit) }
    }

    func pause() {
        pauseRequested = true
    }

    func resume() {
        guard state == .paused else { return }
        pauseRequested = false
        scanTask = Task { await self.runScan() }
    }

    // MARK: - 主流程

    private func runScan(limit: Int? = nil) async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        do {
            state = .preparingModels
            try await engine.prepare()
            try store.open()
        } catch {
            AutoTest.log("[Scanner] 模型/存储初始化失败: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            return
        }

        let assets = Self.fetchRecentAssets(months: 6)
        let done = store.existingIDs()
        var pending = assets.filter { !done.contains($0.localIdentifier) }
        if let limit { pending = Array(pending.prefix(limit)) }
        totalAssets = limit != nil ? pending.count : assets.count
        pendingTotal = pending.count
        indexedCount = done.count
        processedThisRun = 0
        failedThisRun = 0

        guard !pending.isEmpty else {
            state = .finished
            return
        }

        state = .running
        AutoTest.log("[Scanner] 开始扫描，待处理 \(pending.count) 张")
        for asset in pending {
            if pauseRequested || Task.isCancelled {
                state = .paused
                return
            }
            do {
                guard let image = await Self.requestImage(for: asset) else {
                    failedThisRun += 1
                    AutoTest.log("[Scanner] 图片拉取失败: \(asset.localIdentifier)")
                    continue
                }
                let (vector, _) = try await engine.embed(image)
                store.insert(id: asset.localIdentifier, vector: vector)
                processedThisRun += 1
                indexedCount += 1
                if processedThisRun % 10 == 0 {
                    AutoTest.log("[Scanner] 已处理 \(processedThisRun)，平均 \(String(format: "%.0f", await engine.stats.avgMs))ms/张")
                }
            } catch {
                failedThisRun += 1
                AutoTest.log("[Scanner] 处理失败: \(error.localizedDescription)")
            }
            let s = await engine.stats
            lastImageMs = s.lastMs
            avgMs = s.avgMs
        }
        state = .finished
    }

    // MARK: - PhotoKit 访问

    static func fetchRecentAssets(months: Int) -> [PHAsset] {
        let opts = PHFetchOptions()
        let since = Calendar.current.date(byAdding: .month, value: -months, to: Date())! as NSDate
        opts.predicate = NSPredicate(format: "creationDate > %@", since)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: opts)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// 请求指定尺寸的 UIImage，带超时保护（默认 12s）。
    /// - highQualityFormat 回调只触发一次；opportunistic 可能多次回调，只取第一次。
    /// - 超时/取消/出错一律返回 nil，continuation 只 resume 一次（ResumeOnce 抢跑语义），绝不永久挂起。
    static func requestImage(
        for asset: PHAsset,
        targetSize: CGSize = CGSize(width: 512, height: 512),
        deliveryMode: PHImageRequestOptionsDeliveryMode = .highQualityFormat,
        timeout: TimeInterval = 12
    ) async -> UIImage? {
        await withCheckedContinuation { cont in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = deliveryMode
            opts.isNetworkAccessAllowed = true
            opts.resizeMode = .fast

            let once = ResumeOnce()
            let requestIDBox = RequestIDBox()

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard once.tryWin() else { return }
                if let rid = requestIDBox.id {
                    PHImageManager.default().cancelImageRequest(rid)
                }
                AutoTest.log("[Photo] 拉取超时(\(Int(timeout))s，可能卡在 iCloud): \(asset.localIdentifier)")
                cont.resume(returning: nil)
            }

            let rid = PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: opts
            ) { image, info in
                guard once.tryWin() else { return }
                timeoutTask.cancel()
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let error = info?[PHImageErrorKey] as? NSError
                if cancelled {
                    AutoTest.log("[Photo] 拉取被取消: \(asset.localIdentifier)")
                    cont.resume(returning: nil)
                } else if image == nil {
                    AutoTest.log("[Photo] 拉取失败: \(asset.localIdentifier) \(error?.localizedDescription ?? "无错误信息")")
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: image)
                }
            }
            requestIDBox.set(rid)
        }
    }

    /// "只 resume 一次"的抢跑令牌：第一个调用 tryWin() 的返回 true，其余返回 false。
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var won = false

        func tryWin() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if won { return false }
            won = true
            return true
        }
    }

    /// 线程安全的 PHImageRequestID 传递盒（请求 ID 在发起后才产生，超时任务需要读它）。
    private final class RequestIDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: PHImageRequestID?

        var id: PHImageRequestID? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ v: PHImageRequestID) {
            lock.lock()
            value = v
            lock.unlock()
        }
    }
}
