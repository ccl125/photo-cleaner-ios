import Photos
import UIKit

/// 全局缩略图缓存：解决网格滚动时 cell 反复进出视口 → 反复 PHImageManager 拉图的卡顿。
///
/// - NSCache<NSString, UIImage>，costLimit 按解码后位图字节数计（约 150MB 上限）
/// - key = localIdentifier#宽x高（不同尺寸桶分开缓存）
/// - 同一 key 进行中的请求合并（in-flight 去重，不并发拉同一张）
/// - 拉到图后先 `byPreparingForDisplay()` 离屏解码再入缓存——PhotoKit 返回的 UIImage
///   是惰性解码的，直接显示会在主线程解码造成滚动卡顿
/// - 删除照片后由 PhotoDeleter 统一 evict
enum ThumbnailCache {

    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 1200
        c.totalCostLimit = 150 * 1024 * 1024  // ~150MB 解码位图
        return c
    }()

    private static var inflight: [NSString: Task<UIImage?, Never>] = [:]
    private static var knownKeys = Set<NSString>()
    private static let lock = NSLock()

    // MARK: - 对外接口

    /// 同步命中（仅内存读取，可在 body/首帧直接用，避免闪灰）。
    static func cached(for asset: PHAsset, size: CGSize,
                       contentMode: PHImageContentMode = .aspectFill) -> UIImage? {
        cache.object(forKey: key(for: asset.localIdentifier, size: size, contentMode: contentMode))
    }

    /// 异步获取：命中直接返回；未命中走 PhotoKit（opportunistic + fast + 8s 超时）；
    /// 同一 key 在途请求合并。
    static func image(for asset: PHAsset, size: CGSize,
                      contentMode: PHImageContentMode = .aspectFill) async -> UIImage? {
        let k = key(for: asset.localIdentifier, size: size, contentMode: contentMode)
        if let hit = cache.object(forKey: k) { return hit }

        lock.lock()
        if let existing = inflight[k] {
            lock.unlock()
            return await existing.value
        }
        let task = Task { await fetchAndCache(asset: asset, size: size, contentMode: contentMode, key: k) }
        inflight[k] = task
        lock.unlock()

        let image = await task.value
        lock.lock()
        inflight[k] = nil
        lock.unlock()
        return image
    }

    /// 删除照片后清理对应 key（所有尺寸桶）。
    static func evict(ids: [String]) {
        guard !ids.isEmpty else { return }
        let prefixes = ids.map { "\($0)#" }
        lock.lock()
        let doomed = knownKeys.filter { k in prefixes.contains(where: { k.hasPrefix($0) }) }
        for k in doomed { knownKeys.remove(k) }
        lock.unlock()
        for k in doomed { cache.removeObject(forKey: k) }
    }

    // MARK: - 拉取与解码

    private static func fetchAndCache(asset: PHAsset, size: CGSize,
                                      contentMode: PHImageContentMode, key k: NSString) async -> UIImage? {
        guard let raw = await requestThumb(asset: asset, size: size, contentMode: contentMode) else { return nil }
        // 离屏解码（iOS 15+）：把惰性解码挪到后台线程
        let decoded = await raw.byPreparingForDisplay() ?? raw
        let cost = Int(decoded.size.width * decoded.size.height
                       * decoded.scale * decoded.scale * 4)
        cache.setObject(decoded, forKey: k, cost: cost)
        lock.lock()
        knownKeys.insert(k)
        lock.unlock()
        return decoded
    }

    /// PhotoKit 拉缩略图：opportunistic 多次回调只取第一次；8 秒超时取消（防 iCloud 卡死）。
    private static func requestThumb(asset: PHAsset, size: CGSize,
                                     contentMode: PHImageContentMode) async -> UIImage? {
        await withCheckedContinuation { cont in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = true

            let once = ResumeOnce()
            let requestIDBox = RequestIDBox()

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard once.tryWin() else { return }
                if let rid = requestIDBox.id {
                    PHImageManager.default().cancelImageRequest(rid)
                }
                cont.resume(returning: nil)
            }

            let rid = PHImageManager.default().requestImage(
                for: asset,
                targetSize: size,
                contentMode: contentMode,
                options: opts
            ) { image, _ in
                guard once.tryWin() else { return }
                timeoutTask.cancel()
                cont.resume(returning: image)
            }
            requestIDBox.set(rid)
        }
    }

    private static func key(for id: String, size: CGSize,
                            contentMode: PHImageContentMode) -> NSString {
        let mode = contentMode == .aspectFit ? "fit" : "fill"
        return "\(id)#\(Int(size.width))x\(Int(size.height))\(mode)" as NSString
    }

    /// "只 resume 一次"抢跑令牌（与 LibraryScanner 内部同款模式）。
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
