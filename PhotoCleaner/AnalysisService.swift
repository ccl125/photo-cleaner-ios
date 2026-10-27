import Foundation
import Photos
import SwiftUI
import UIKit

/// 分析结果的磁盘缓存（Documents/analysis_cache.json）。
/// 失效策略：indexedCount 与当前向量库条数不一致即失效；删除后经 applyDeletions 同步更新。
struct CachedAnalysis: Codable, Equatable {
    var version: Int = 1
    var generatedAt: Date
    var indexedCount: Int
    var groups: [CachedGroup]
}

struct CachedGroup: Codable, Equatable {
    var tier: String            // "duplicate" / "similar"
    var assetIDs: [String]
    var keepIDs: [String]
    var recommendedID: String?
    var sizes: [String: Int64]
}

/// 相似分组分析的统一入口：ResultsView 展示、首页自动触发共用同一管线。
/// 管线逻辑（findGroups + 打分 + 特征指纹验证 + 降级）与 ResultsView 原实现一致，只做了搬移。
@MainActor
final class AnalysisService: ObservableObject {

    static let shared = AnalysisService()

    @Published private(set) var analysis: CachedAnalysis?
    @Published private(set) var hasData = false       // 有缓存或已完成一次计算
    @Published private(set) var analyzing = false     // 无数据的全量计算中
    @Published private(set) var refreshing = false    // 有缓存、后台重算中
    @Published var note = "正在计算相似分组…"
    @Published var progress: Double = 0
    @Published private(set) var fromCache = false

    private var running = false

    // MARK: - 缓存

    private static var cacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("analysis_cache.json")
    }

    static func loadCacheFile() -> CachedAnalysis? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(CachedAnalysis.self, from: data)
    }

    private func saveCache() {
        guard let analysis,
              let data = try? JSONEncoder().encode(analysis) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    /// 删除完成后同步缓存：移除已删成员、丢弃空组/单张组，indexedCount 对齐当前库。
    func applyDeletions(_ deletedIDs: [String], store: EmbeddingStore) {
        guard var a = analysis else { return }
        let deleted = Set(deletedIDs)
        a.groups = a.groups.compactMap { g in
            var g = g
            g.assetIDs.removeAll { deleted.contains($0) }
            g.keepIDs.removeAll { deleted.contains($0) }
            for id in deleted { g.sizes.removeValue(forKey: id) }
            if let r = g.recommendedID, deleted.contains(r) { g.recommendedID = nil }
            return g.assetIDs.count >= 2 ? g : nil
        }
        a.indexedCount = store.count()
        a.generatedAt = Date()
        analysis = a
        saveCache()
        AutoTest.log("[Analysis] 缓存已更新：删除 \(deleted.count) 张，剩 \(a.groups.count) 组")
    }

    // MARK: - 分析入口

    /// 缓存有效（索引数未变）→ 立即展示 + 后台重算；否则全量计算。
    func analyze(scanner: LibraryScanner, force: Bool = false) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let store = scanner.store
        try? store.open()

        if !force, let cached = Self.loadCacheFile(), cached.indexedCount == store.count() {
            analysis = cached
            hasData = true
            fromCache = true
            refreshing = true
            AutoTest.log("[Analysis] 命中缓存（\(cached.groups.count) 组，\(cached.generatedAt)），后台刷新中")
            await compute(scanner: scanner)
            refreshing = false
        } else {
            fromCache = false
            hasData = false
            analyzing = true
            await compute(scanner: scanner)
            analyzing = false
        }
    }

    // MARK: - 计算管线（移植自 ResultsView.analyze，行为一致）

    private func compute(scanner: LibraryScanner) async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        note = "正在计算相似分组…"
        progress = 0
        let store = scanner.store
        let found = await Task.detached(priority: .userInitiated) { [store] in
            DedupAnalyzer.findGroups(store: store) { p in
                Task { @MainActor in
                    self.progress = p
                    self.note = String(format: "正在计算相似分组… %.0f%%", p * 100)
                }
            }
        }.value
        AutoTest.log("[AutoTest] 分组完成: \(found.count) 组（重复 \(found.count(where: { $0.tier == .duplicate }))，相似 \(found.count(where: { $0.tier == .similar }))")

        var out: [CachedGroup] = []
        var dupOrdinal = 0
        let dupTotal = found.count(where: { $0.tier == .duplicate })
        for g in found {
            let assets = Self.fetchAssets(ids: g.assetIDs)
            guard !assets.isEmpty else { continue }

            // 文件体积在后台线程批量取，避免主线程同步读 PhotoKit 元数据
            let sizes = await Task.detached(priority: .userInitiated) {
                var m: [String: Int64] = [:]
                for a in assets { m[a.localIdentifier] = CleanupScanner.fileSize(of: a) }
                return m
            }.value

            switch g.tier {
            case .duplicate:
                dupOrdinal += 1
                if AutoTest.enabled {
                    // 自测模式：跳过打分与验证，默认保留第一张
                    out.append(CachedGroup(
                        tier: "duplicate", assetIDs: g.assetIDs,
                        keepIDs: [g.assetIDs.first ?? ""], recommendedID: nil, sizes: sizes))
                    continue
                }
                note = "正在为第 \(dupOrdinal)/\(dupTotal) 个重复组打分…"
                progress = Double(dupOrdinal) / Double(max(dupTotal, 1))
                let (_, recommended, images) = await scoreMembers(
                    assets, sizes: sizes, label: "第 \(dupOrdinal)/\(dupTotal) 个重复组")
                let anchor = recommended ?? g.assetIDs.first ?? ""

                // 第二级像素级验证：特征指纹距离过大的成员（不同姿势/手势）降级到相似组
                let distances = await Task.detached(priority: .userInitiated) {
                    FeaturePrintVerifier.distancesToAnchor(anchorID: anchor, images: images)
                }.value
                var confirmed: [PHAsset] = []
                var demoted: [PHAsset] = []
                for a in assets {
                    if a.localIdentifier == anchor { confirmed.append(a); continue }
                    guard let d = distances[a.localIdentifier], d.isFinite else {
                        demoted.append(a)
                        AutoTest.log("[Analyze] 组 \(dupOrdinal) 成员 \(a.localIdentifier.prefix(8)) 降级: 未验证（大组截断或拉图失败）")
                        continue
                    }
                    let sameSize = a.pixelWidth == (assets.first { $0.localIdentifier == anchor }?.pixelWidth ?? -1)
                        && a.pixelHeight == (assets.first { $0.localIdentifier == anchor }?.pixelHeight ?? -2)
                    let anchorDate = assets.first { $0.localIdentifier == anchor }?.creationDate
                    let closeTime: Bool
                    if let ad = anchorDate, let cd = a.creationDate {
                        closeTime = abs(cd.timeIntervalSince(ad)) <= 600
                    } else {
                        closeTime = true
                    }
                    if d <= FeaturePrintVerifier.distanceThreshold && sameSize && closeTime {
                        confirmed.append(a)
                    } else {
                        demoted.append(a)
                        AutoTest.log("[Analyze] 组 \(dupOrdinal) 成员 \(a.localIdentifier.prefix(8)) 降级: 距离=\(String(format: "%.2f", d)) 同尺寸=\(sameSize) 时间近=\(closeTime)")
                    }
                }
                if distances.isEmpty {
                    AutoTest.log("[Analyze] 组 \(dupOrdinal) 特征指纹计算失败（锚点无指纹），跳过二级验证")
                }
                let allDist = distances
                    .filter { $0.key != anchor }
                    .map { "\($0.key.prefix(8))=\(String(format: "%.2f", $0.value))" }
                    .joined(separator: ",")
                if !allDist.isEmpty {
                    AutoTest.log("[Analyze] 组 \(dupOrdinal) 指纹距离: \(allDist)")
                }
                if !demoted.isEmpty {
                    let distDesc = demoted.map {
                        "\($0.localIdentifier.prefix(8))=\(String(format: "%.1f", distances[$0.localIdentifier] ?? -1))"
                    }.joined(separator: ",")
                    AutoTest.log("[Analyze] 组 \(dupOrdinal) 降级 \(demoted.count) 张到相似组: \(distDesc)")
                }

                if confirmed.count < 2 {
                    out.append(CachedGroup(
                        tier: "similar", assetIDs: g.assetIDs,
                        keepIDs: g.assetIDs, recommendedID: nil, sizes: sizes))
                } else {
                    out.append(CachedGroup(
                        tier: "duplicate", assetIDs: confirmed.map(\.localIdentifier),
                        keepIDs: [anchor], recommendedID: recommended, sizes: sizes))
                    if !demoted.isEmpty, let first = confirmed.first {
                        out.append(CachedGroup(
                            tier: "similar",
                            assetIDs: [first.localIdentifier] + demoted.map(\.localIdentifier),
                            keepIDs: ([first] + demoted).map(\.localIdentifier),
                            recommendedID: nil, sizes: sizes))
                    }
                }
            case .similar:
                out.append(CachedGroup(
                    tier: "similar", assetIDs: g.assetIDs,
                    keepIDs: g.assetIDs, recommendedID: nil, sizes: sizes))
            }
        }

        let result = CachedAnalysis(generatedAt: Date(), indexedCount: store.count(), groups: out)
        analysis = result
        hasData = true
        fromCache = false
        saveCache()
        let dupN = out.count(where: { $0.tier == "duplicate" })
        AutoTest.log("[AutoTest] 分析完成：重复组 \(dupN)，相似组 \(out.count - dupN)")
        scanner.autoTestStatus += "｜分析完成: 重复组=\(dupN), 相似组=\(out.count - dupN)"
    }

    // MARK: - 打分（ResultsView 的相似组惰性按钮也走这里）

    /// 对一组成员做质量打分：单组上限 20 个（按文件体积取大），256px + opportunistic + 8s 超时。
    func scoreMembers(
        _ assets: [PHAsset], sizes: [String: Int64], label: String
    ) async -> (scores: [String: QualityScorer.MemberScore], recommended: String?, images: [String: UIImage]) {
        let scored: [PHAsset]
        if assets.count > 20 {
            scored = Array(assets
                .sorted { (sizes[$0.localIdentifier] ?? 0) > (sizes[$1.localIdentifier] ?? 0) }
                .prefix(20))
        } else {
            scored = assets
        }
        AutoTest.log("[Analyze] \(label)，成员 \(assets.count) 个，实际打分 \(scored.count) 个")

        var images: [String: UIImage] = [:]
        for asset in scored {
            if let img = await LibraryScanner.requestImage(
                for: asset,
                targetSize: CGSize(width: 256, height: 256),
                deliveryMode: .opportunistic,
                timeout: 8
            ) {
                images[asset.localIdentifier] = img
            } else {
                AutoTest.log("[Analyze] 成员图拉取失败（超时/iCloud）: \(asset.localIdentifier)")
            }
        }
        let result = await Task.detached(priority: .userInitiated) {
            QualityScorer.scoreGroup(assets: scored, images: images)
        }.value
        return (result.scores, result.recommended, images)
    }

    static func fetchAssets(ids: [String]) -> [PHAsset] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byID: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        return ids.compactMap { byID[$0] }
    }
}
