import Photos
import SwiftUI
import UIKit

/// 废片候选队列：卡片式速审，左滑/左钮删除，右滑/右钮保留。
/// 候选来源：quality 表（扫描流水线写入），过滤截图（截图走清理清单），
/// junkScore >= 阈值（实验室滑块，默认 0.6），按分数降序。
struct JunkReviewView: View {
    @EnvironmentObject private var scanner: LibraryScanner
    let threshold: Double

    struct Candidate: Identifiable {
        let asset: PHAsset
        let score: Double
        let reasons: [String]
        var id: String { asset.localIdentifier }
    }

    @State private var candidates: [Candidate] = []
    @State private var index = 0
    @State private var toDelete: [Candidate] = []
    @State private var keptCount = 0
    @State private var loading = true
    @State private var showConfirm = false
    @State private var deleting = false
    @State private var errorMessage: String?
    @State private var dragOffset: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if loading {
                ProgressView("正在挑选废片候选…")
            } else if candidates.isEmpty {
                Theme.EmptyState(
                    systemImage: "sparkles",
                    title: "没有废片候选",
                    hint: "当前阈值 \(String(format: "%.2f", threshold))。想审更多可在 设置 → 实验室 调低阈值。"
                )
            } else if index >= candidates.count {
                reviewDoneView
            } else {
                cardView
            }
        }
        .navigationTitle("废片清理")
        .alert("确认删除？", isPresented: $showConfirm) {
            Button("删除", role: .destructive) { Task { await commitDelete() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从相册删除 \(toDelete.count) 张照片，系统会再次向你确认。")
        }
        .alert("出错了", isPresented: .constant(errorMessage != nil)) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await load() }
    }

    // MARK: - 速审卡片

    private var cardView: some View {
        let c = candidates[index]
        return VStack(spacing: 16) {
            Text("\(index + 1) / \(candidates.count)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)

            JunkCard(candidate: c)
                .offset(x: dragOffset)
                .rotationEffect(.degrees(Double(dragOffset) / 30))
                .animation(.interactiveSpring, value: dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { dragOffset = $0.translation.width }
                        .onEnded { v in
                            if v.translation.width < -80 {
                                decide(.delete)
                            } else if v.translation.width > 80 {
                                decide(.keep)
                            }
                            dragOffset = 0
                        }
                )

            HStack {
                ForEach(c.reasons, id: \.self) { r in
                    Theme.Badge(text: r, systemImage: "exclamationmark.triangle", color: Theme.warning)
                }
                Text(String(format: "废片分 %.2f", c.score))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }

            HStack(spacing: 40) {
                Button { decide(.delete) } label: {
                    Label("删除", systemImage: "trash")
                        .font(.title2)
                        .frame(width: 120, height: 56)
                }
                .buttonStyle(.bordered)
                .tint(Theme.danger)
                .accessibilityIdentifier("junkDeleteButton")

                Button { decide(.keep) } label: {
                    Label("保留", systemImage: "heart")
                        .font(.title2)
                        .frame(width: 120, height: 56)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.success)
                .accessibilityIdentifier("junkKeepButton")
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - 审完结算

    private var reviewDoneView: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "checkmark.circle").font(.system(size: 56)).foregroundStyle(Theme.success)
            Text("审完了 \(candidates.count) 张").font(.title2.bold()).foregroundStyle(Theme.ink)
            Text("保留 \(keptCount) 张 · 待删 \(toDelete.count) 张")
                .foregroundStyle(Theme.muted)
            if !toDelete.isEmpty {
                Button(role: .destructive) { showConfirm = true } label: {
                    Text("删除 \(toDelete.count) 张")
                        .frame(minWidth: 160)
                }
                .dangerButton()
                .frame(maxWidth: 280)
                .disabled(deleting)
                .accessibilityIdentifier("junkCommitDeleteButton")
            }
            Button("返回") { dismiss() }
                .secondaryButton()
                .frame(maxWidth: 280)
        }
        .padding()
    }

    // MARK: - 逻辑

    private enum Decision { case keep, delete }

    private func decide(_ d: Decision) {
        let c = candidates[index]
        switch d {
        case .keep:
            keptCount += 1
            AutoTest.log("[Junk] 保留 \(c.id) score=\(String(format: "%.2f", c.score)) \(c.reasons.joined(separator: "/"))")
        case .delete:
            toDelete.append(c)
            AutoTest.log("[Junk] 删除 \(c.id) score=\(String(format: "%.2f", c.score)) \(c.reasons.joined(separator: "/"))")
        }
        index += 1
        dragOffset = 0
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let store = scanner.store
        let thr = threshold
        let found = await Task.detached(priority: .userInitiated) {
            Self.loadCandidates(store: store, threshold: thr)
        }.value
        candidates = found.list
    }

    /// 候选计算（后台线程）：quality 表 → 过滤截图 → 打分 → 阈值过滤 → 降序。
    /// 首页"待审数量"和本页共用。返回 (candidates, 各原因分布统计)。
    static func loadCandidates(store: EmbeddingStore, threshold: Double)
        -> (list: [Candidate], stats: (blur: Int, bright: Int, face: Int)) {
        let quality = store.fetchAllQuality()
        guard !quality.isEmpty else { return ([], (0, 0, 0)) }

        let result = PHAsset.fetchAssets(withLocalIdentifiers: Array(quality.keys), options: nil)
        var assets: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }

        var list: [Candidate] = []
        var stats = (blur: 0, bright: 0, face: 0)
        for (id, rec) in quality {
            // 废片队列只针对相机照片，截图走清理清单
            guard let asset = assets[id],
                  !asset.mediaSubtypes.contains(.photoScreenshot) else { continue }
            let (score, reasons) = JunkScorer.score(rec)
            guard JunkScorer.isCandidate(score: score, threshold: threshold) else { continue }
            if reasons.contains("模糊") { stats.blur += 1 }
            if reasons.contains("黑帧") || reasons.contains("过曝") { stats.bright += 1 }
            if reasons.contains("闭眼/表情") { stats.face += 1 }
            list.append(Candidate(asset: asset, score: score, reasons: reasons))
        }
        list.sort { $0.score > $1.score }
        AutoTest.log("[Junk] 候选 \(list.count) 张（阈值 \(String(format: "%.2f", threshold))）：模糊 \(stats.blur) / 黑白帧 \(stats.bright) / 闭眼 \(stats.face)")
        return (list, stats)
    }

    private func commitDelete() async {
        deleting = true
        defer { deleting = false }
        let victims = toDelete.map(\.asset)
        let ids = toDelete.map(\.id)
        do {
            try await PhotoDeleter.delete(victims)
            scanner.store.deleteEverywhere(ids: ids)
            AutoTest.log("[Junk] 已删除 \(ids.count) 张废片")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 单张废片卡片（大图）。
private struct JunkCard: View {
    let candidate: JunkReviewView.Candidate
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(.gray.opacity(0.1))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 420)
        .task(id: candidate.id) {
            image = await Self.load(asset: candidate.asset)
        }
    }

    static func load(asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { cont in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = true
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 1200, height: 1200),
                contentMode: .aspectFit,
                options: opts
            ) { image, _ in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: image)
            }
        }
    }
}
