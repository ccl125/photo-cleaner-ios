import Foundation
import Photos

/// 清理清单的元数据筛选：截图 / 录屏 / 大视频。零推理成本，纯 PHFetchOptions + 资源大小。
enum CleanupScanner {

    struct Summary: Sendable {
        var screenshotCount = 0
        var screenshotBytes: Int64 = 0
        var recordingCount = 0
        var recordingBytes: Int64 = 0
        var largeVideoCount = 0
        var largeVideoBytes: Int64 = 0
    }

    // MARK: - 各类取数

    static func screenshots() -> [PHAsset] {
        subtypeFetch(.image, subtype: .photoScreenshot)
    }

    static func screenRecordings() -> [PHAsset] {
        subtypeFetch(.video, subtype: .videoScreenRecording)
    }

    /// 全部视频按文件大小降序取前 limit 个。
    static func largeVideos(limit: Int = 50) -> [PHAsset] {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "mediaType == %ld", PHAssetMediaType.video.rawValue)
        let result = PHAsset.fetchAssets(with: opts)
        // 先取一次 fileSize 再排序，避免比较器里重复读 PHAssetResource
        var sized: [(asset: PHAsset, size: Int64)] = []
        sized.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            sized.append((asset, fileSize(of: asset)))
        }
        sized.sort { $0.size > $1.size }
        return sized.prefix(limit).map(\.asset)
    }

    // MARK: - 汇总

    static func summary() -> Summary {
        var s = Summary()
        let shots = screenshots()
        s.screenshotCount = shots.count
        s.screenshotBytes = totalBytes(of: shots)
        let recs = screenRecordings()
        s.recordingCount = recs.count
        s.recordingBytes = totalBytes(of: recs)
        let videos = largeVideos()
        s.largeVideoCount = videos.count
        s.largeVideoBytes = totalBytes(of: videos)
        return s
    }

    // MARK: - 工具

    static func fileSize(of asset: PHAsset) -> Int64 {
        PHAssetResource.assetResources(for: asset).first?.value(forKey: "fileSize") as? Int64 ?? 0
    }

    static func totalBytes(of assets: [PHAsset]) -> Int64 {
        assets.reduce(0) { $0 + fileSize(of: $1) }
    }

    private static func subtypeFetch(_ mediaType: PHAssetMediaType, subtype: PHAssetMediaSubtype) -> [PHAsset] {
        let opts = PHFetchOptions()
        opts.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "mediaType == %ld", mediaType.rawValue),
            NSPredicate(format: "(mediaSubtypes & %ld) != 0", subtype.rawValue),
        ])
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: opts)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }
}

/// 统一删除入口（系统会弹确认框，照片进"最近删除"）。
enum PhotoDeleter {
    static func delete(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
        // 删除成功后清掉缩略图缓存，避免已删照片残留
        ThumbnailCache.evict(ids: assets.map(\.localIdentifier))
    }

    /// 用户在系统删除确认框点了"取消"（PHPhotosErrorDomain 3072）——正常路径，不该报错。
    static func isCancellation(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == PHPhotosErrorDomain && e.code == PHPhotosError.Code.userCancelled.rawValue
    }
}
