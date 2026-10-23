import Photos
import SwiftUI
import UIKit

/// 结果页：分段展示"重复照片"(>0.93) 与"相似照片"(0.80–0.93)。
/// 每组自动质量打分并推荐保留项：
///   - 重复组：默认保留推荐项、其余勾选删除（红色标记）
///   - 相似组：只打"推荐"徽标，默认全部保留（橙色弱强调），由用户手动挑选
struct ResultsView: View {
    @EnvironmentObject private var scanner: LibraryScanner

    struct GroupModel: Identifiable {
        let id = UUID()
        var tier: DedupAnalyzer.Tier
        var assets: [PHAsset]
        var keepIDs: Set<String>
        var recommendedID: String?
        var scores: [String: QualityScorer.MemberScore] = [:]
        var sizes: [String: Int64] = [:]
        var totalBytes: Int64 = 0
        var isScoring = false
        var deleteIDs: [String] { assets.map(\.localIdentifier).filter { !keepIDs.contains($0) } }
    }

    @State private var groups: [GroupModel] = []
    @State private var analyzing = true
    @State private var analyzeNote = "正在计算相似分组…"
    @State private var groupProgress: Double = 0
    @State private var deleting = false
    @State private var showConfirm = false
    @State private var errorMessage: String?

    private var dupIndices: [Int] { groups.indices.filter { groups[$0].tier == .duplicate } }
    private var simIndices: [Int] { groups.indices.filter { groups[$0].tier == .similar } }
    private var selectedDeleteCount: Int { groups.reduce(0) { $0 + $1.deleteIDs.count } }
    private var selectedDeleteBytes: Int64 {
        groups.reduce(0) { sum, g in
            sum + Self.fileSize(of: g.assets.filter { !g.keepIDs.contains($0.localIdentifier) })
        }
    }

    var body: some View {
        Group {
            if analyzing {
                VStack(spacing: 12) {
                    ProgressView()
                    ProgressView(value: groupProgress)
                        .frame(maxWidth: 280)
                    Text(analyzeNote).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else if groups.isEmpty {
                ContentUnavailableView("没有发现相似照片", systemImage: "photo.on.rectangle.angled")
            } else {
                groupList
            }
        }
        .navigationTitle("相似照片分组")
        .accessibilityIdentifier("resultsView")
        .toolbar {
            if !scanner.autoTestStatus.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Text(scanner.autoTestStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("autoTestStatus")
                }
            }
        }
        .toolbar {
            if !groups.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) { showConfirm = true } label: {
                        Text("删除选中 \(selectedDeleteCount) 张（约 \(Self.formatBytes(selectedDeleteBytes))）")
                    }
                    .disabled(selectedDeleteCount == 0 || deleting)
                }
            }
        }
        .alert("确认删除？", isPresented: $showConfirm) {
            Button("删除", role: .destructive) { Task { await deleteSelected() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从相册删除 \(selectedDeleteCount) 张照片，系统会再次向你确认。照片会先进入“最近删除”。")
        }
        .alert("出错了", isPresented: .constant(errorMessage != nil)) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await analyze() }
    }

    // MARK: - 分段列表

    private var groupList: some View {
        List {
            if !dupIndices.isEmpty {
                Section {
                    ForEach(dupIndices, id: \.self) { i in
                        groupRow($groups[i], ordinal: i + 1)
                    }
                } header: {
                    Text("重复照片 · \(dupIndices.count) 组 · 建议删除 \(dupIndices.reduce(0) { $0 + groups[$1].deleteIDs.count }) 张")
                }
            }
            if !simIndices.isEmpty {
                Section {
                    ForEach(simIndices, id: \.self) { i in
                        groupRow($groups[i], ordinal: i + 1)
                    }
                } header: {
                    Text("相似照片（同主题/连拍）· \(simIndices.count) 组")
                } footer: {
                    Text("相似组默认不勾选删除；点“为这组打分推荐”可查看质量推荐，点击缩略图手动挑选。")
                }
            }
        }
    }

    private func groupRow(_ group: Binding<GroupModel>, ordinal: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal) {
                LazyHGrid(rows: [GridItem(.fixed(110))], spacing: 8) {
                    ForEach(group.wrappedValue.assets, id: \.localIdentifier) { asset in
                        AssetCell(
                            asset: asset,
                            isKept: group.wrappedValue.keepIDs.contains(asset.localIdentifier),
                            isRecommended: group.wrappedValue.recommendedID == asset.localIdentifier,
                            tier: group.wrappedValue.tier,
                            sizeText: group.wrappedValue.sizes[asset.localIdentifier]
                                .map(ResultsView.formatBytes)
                        ) {
                            toggle(asset, in: group)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 118)
            Text(headerText(group.wrappedValue, ordinal: ordinal))
                .font(.caption)
                .foregroundStyle(.secondary)
            // 相似组惰性打分：不预拉图，用户点击后才对该组打分出推荐徽标
            if group.wrappedValue.tier == .similar && group.wrappedValue.recommendedID == nil {
                if group.wrappedValue.isScoring {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("打分中…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button("为这组打分推荐") { scoreSimilarGroup(group) }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private func headerText(_ group: GroupModel, ordinal: Int) -> String {
        switch group.tier {
        case .duplicate:
            return "第 \(ordinal) 组 · \(group.assets.count) 张 · 将删 \(group.deleteIDs.count) 张"
        case .similar:
            return "第 \(ordinal) 组 · \(group.assets.count) 张 · 已勾选删除 \(group.deleteIDs.count) 张"
        }
    }

    private func toggle(_ asset: PHAsset, in group: Binding<GroupModel>) {
        let id = asset.localIdentifier
        if group.wrappedValue.keepIDs.contains(id) {
            if group.wrappedValue.keepIDs.count > 1 { group.keepIDs.wrappedValue.remove(id) }
        } else {
            group.keepIDs.wrappedValue.insert(id)
        }
    }

    // MARK: - 分析（分组 + 质量打分）

    /// 重复组立即打分（成员 >20 时只对体积前 20 打分）；相似组惰性打分（进列表后再按需触发）。
    /// 自测模式（-autoTest）跳过所有打分，findGroups 出结果即渲染，压缩回归时长。
    private func analyze() async {
        analyzing = true
        defer { analyzing = false }

        analyzeNote = "正在计算相似分组…"
        groupProgress = 0
        let store = scanner.store
        let found = await Task.detached(priority: .userInitiated) { [store] in
            DedupAnalyzer.findGroups(store: store) { p in
                // 回调在后台线程触发，回主线程更新进度
                Task { @MainActor in
                    self.groupProgress = p
                    self.analyzeNote = String(format: "正在计算相似分组… %.0f%%", p * 100)
                }
            }
        }.value
        AutoTest.log("[AutoTest] 分组完成: \(found.count) 组（重复 \(found.count(where: { $0.tier == .duplicate }))，相似 \(found.count(where: { $0.tier == .similar }))")

        var models: [GroupModel] = []
        var dupOrdinal = 0
        let dupTotal = found.count(where: { $0.tier == .duplicate })
        for g in found {
            let assets = fetchAssets(ids: g.assetIDs)
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
                    // 自测模式：跳过打分（打分链路由相似组的惰性按钮覆盖），默认保留第一张
                    models.append(GroupModel(
                        tier: .duplicate,
                        assets: assets,
                        keepIDs: [g.assetIDs.first ?? ""],
                        recommendedID: nil,
                        sizes: sizes,
                        totalBytes: sizes.values.reduce(0, +)
                    ))
                    continue
                }
                analyzeNote = "正在为第 \(dupOrdinal)/\(dupTotal) 个重复组打分…"
                let (scores, recommended) = await scoreMembers(
                    assets, label: "第 \(dupOrdinal)/\(dupTotal) 个重复组")
                // 重复组：默认保留推荐项，其余勾选删除
                let keep: Set<String> = [recommended ?? g.assetIDs.first ?? ""]
                models.append(GroupModel(
                    tier: .duplicate,
                    assets: assets,
                    keepIDs: keep,
                    recommendedID: recommended,
                    scores: scores,
                    sizes: sizes,
                    totalBytes: sizes.values.reduce(0, +)
                ))
            case .similar:
                // 相似组：保守，默认全保留；推荐徽标留空，由"为这组打分推荐"按钮惰性触发
                models.append(GroupModel(
                    tier: .similar,
                    assets: assets,
                    keepIDs: Set(g.assetIDs),
                    recommendedID: nil,
                    sizes: sizes,
                    totalBytes: sizes.values.reduce(0, +)
                ))
            }
        }
        groups = models
        let dupN = models.count(where: { $0.tier == .duplicate })
        let simN = models.count - dupN
        AutoTest.log("[AutoTest] 分析完成：重复组 \(dupN)，相似组 \(simN)")
        scanner.autoTestStatus += "｜分析完成: 重复组=\(dupN), 相似组=\(simN)"
    }

    /// 对一组成员做质量打分：单组上限 20 个（按文件体积取大），256px + opportunistic + 8s 超时。
    private func scoreMembers(
        _ assets: [PHAsset], label: String
    ) async -> (scores: [String: QualityScorer.MemberScore], recommended: String?) {
        let scored: [PHAsset]
        if assets.count > 20 {
            scored = Array(assets
                .sorted { CleanupScanner.fileSize(of: $0) > CleanupScanner.fileSize(of: $1) }
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
        return await Task.detached(priority: .userInitiated) {
            QualityScorer.scoreGroup(assets: scored, images: images)
        }.value
    }

    /// 相似组的惰性打分入口（按钮触发）：只对该组拉图打分，更新推荐徽标，不改勾选状态。
    private func scoreSimilarGroup(_ group: Binding<GroupModel>) {
        guard !group.wrappedValue.isScoring else { return }
        group.isScoring.wrappedValue = true
        Task {
            let (scores, recommended) = await scoreMembers(group.wrappedValue.assets, label: "相似组（手动）")
            group.scores.wrappedValue = scores
            group.recommendedID.wrappedValue = recommended
            group.isScoring.wrappedValue = false
        }
    }

    private func fetchAssets(ids: [String]) -> [PHAsset] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byID: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        return ids.compactMap { byID[$0] }
    }

    private func deleteSelected() async {
        deleting = true
        defer { deleting = false }
        let ids = groups.flatMap(\.deleteIDs)
        let assets = fetchAssets(ids: ids)
        do {
            try await PhotoDeleter.delete(assets)
            scanner.store.delete(ids: ids)
            await analyze()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 工具

    static func fileSize(of assets: [PHAsset]) -> Int64 {
        CleanupScanner.totalBytes(of: assets)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// 单张缩略图 + 保留/删除/推荐标记。
private struct AssetCell: View {
    let asset: PHAsset
    let isKept: Bool
    let isRecommended: Bool
    let tier: DedupAnalyzer.Tier
    let sizeText: String?
    let onTap: () -> Void

    @State private var image: UIImage?

    private var markColor: Color {
        if isKept { return tier == .duplicate ? .green : .orange }
        return tier == .duplicate ? .red : .gray
    }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomTrailing) {
                thumb
                    .frame(width: 110, height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(markColor, lineWidth: 3)
                    )
                    .opacity(isKept ? 1 : (tier == .duplicate ? 0.55 : 0.75))
                Image(systemName: isKept ? "checkmark.circle.fill" : "trash.circle.fill")
                    .foregroundStyle(markColor)
                    .padding(4)
            }
            .overlay(alignment: .topLeading) {
                if isRecommended {
                    Text("推荐")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let sizeText {
                    Text(sizeText)
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: asset.localIdentifier) {
            // 自测模式下跳过缩略图加载，保持无障碍树轻量（XCT 快照 60s 超时）
            guard !AutoTest.enabled else { return }
            image = await Self.loadThumbnail(asset: asset)
        }
    }

    private var thumb: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.15)
            }
        }
    }

    static func loadThumbnail(asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { cont in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = true
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 220, height: 220),
                contentMode: .aspectFill,
                options: opts
            ) { image, _ in
                // opportunistic 可能回调两次（先低清后高清），只取第一次
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: image)
            }
        }
    }
}
