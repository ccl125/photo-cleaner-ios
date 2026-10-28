import Photos
import SwiftUI
import UIKit

/// 结果页：分段展示"重复照片"(>0.97) 与"相似照片"(0.90–0.97)。
/// 数据源为 AnalysisService（缓存优先 + 后台刷新）：
///   - 缓存有效（索引数未变）→ 秒开上次结果，顶部提示后台刷新中，完成后热更新
///   - 无缓存/索引数变了 → 全量分析（重复组打分 + 特征指纹验证 + 降级）
///   - 用户已手动改过勾选时不被后台刷新打断；删除后缓存就地更新
struct ResultsView: View {
    @EnvironmentObject private var scanner: LibraryScanner
    @ObservedObject private var service = AnalysisService.shared

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
    @State private var userTouched = false   // 用户改过勾选后，后台刷新不打断当前选择
    @State private var deleting = false
    @State private var showConfirm = false
    @State private var errorMessage: String?

    private var dupIndices: [Int] { groups.indices.filter { groups[$0].tier == .duplicate } }
    private var simIndices: [Int] { groups.indices.filter { groups[$0].tier == .similar } }
    private var selectedDeleteCount: Int { groups.reduce(0) { $0 + $1.deleteIDs.count } }
    private var selectedDeleteBytes: Int64 {
        // 直接读分析阶段已缓存的 sizes，不在主线程重复查 PHAssetResource
        groups.reduce(0) { sum, g in
            sum + g.deleteIDs.reduce(0) { $0 + (g.sizes[$1] ?? 0) }
        }
    }

    var body: some View {
        Group {
            if service.analyzing && !service.hasData {
                VStack(spacing: Theme.Spacing.md) {
                    ProgressView()
                        .tint(Theme.primary)
                    ProgressView(value: service.progress)
                        .tint(Theme.primary)
                        .frame(maxWidth: 280)
                    Text(service.note).foregroundStyle(Theme.muted)
                        .monospacedDigit()
                }
            } else if groups.isEmpty {
                Theme.EmptyState(
                    systemImage: "photo.on.rectangle.angled",
                    title: "没有发现相似照片",
                    hint: "换个时间段或继续扫描扩充索引后再看。"
                )
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
                        Label("删除选中 \(selectedDeleteCount) 张（约 \(Self.formatBytes(selectedDeleteBytes))）",
                              systemImage: "trash")
                    }
                    .tint(Theme.danger)
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
        .task { await runAnalysis() }
        .onChange(of: service.analysis) { _, newValue in
            // 后台刷新完成 → 热更新；用户已改过勾选则保留当前选择
            guard !userTouched, newValue != nil else { return }
            rebuildModels()
        }
    }

    // MARK: - 数据装配

    private func runAnalysis() async {
        // 自测模式行为不变：始终全量分析
        await service.analyze(scanner: scanner, force: AutoTest.enabled)
        rebuildModels()
    }

    private func rebuildModels() {
        guard let analysis = service.analysis else { return }
        groups = analysis.groups.map { g in
            let assets = AnalysisService.fetchAssets(ids: g.assetIDs)
            return GroupModel(
                tier: g.tier == "duplicate" ? .duplicate : .similar,
                assets: assets,
                keepIDs: Set(g.keepIDs),
                recommendedID: g.recommendedID,
                sizes: g.sizes,
                totalBytes: assets.reduce(0) { $0 + (g.sizes[$1.localIdentifier] ?? 0) }
            )
        }
    }

    // MARK: - 分段列表

    private var groupList: some View {
        List {
            if service.refreshing, let at = service.analysis?.generatedAt {
                Section {
                    Label("上次分析于 \(at.formatted(date: .omitted, time: .shortened))，后台刷新中…",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }
            if !dupIndices.isEmpty {
                Section {
                    ForEach(dupIndices, id: \.self) { i in
                        groupRow($groups[i], ordinal: i + 1)
                    }
                } header: {
                    Text("重复照片 · \(dupIndices.count) 组 · 建议删除 \(dupIndices.reduce(0) { $0 + groups[$1].deleteIDs.count }) 张")
                        .foregroundStyle(Theme.danger)
                }
            }
            if !simIndices.isEmpty {
                Section {
                    ForEach(simIndices, id: \.self) { i in
                        groupRow($groups[i], ordinal: i + 1)
                    }
                } header: {
                    Text("相似照片（同主题/连拍）· \(simIndices.count) 组")
                        .foregroundStyle(Theme.warning)
                } footer: {
                    Text("相似组默认不勾选删除；点“为这组打分推荐”可查看质量推荐，点击缩略图手动挑选。")
                        .foregroundStyle(Theme.muted)
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
                .foregroundStyle(Theme.muted)
            // 相似组惰性打分：不预拉图，用户点击后才对该组打分出推荐徽标
            if group.wrappedValue.tier == .similar && group.wrappedValue.recommendedID == nil {
                if group.wrappedValue.isScoring {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("打分中…").font(.caption).foregroundStyle(Theme.muted)
                    }
                } else {
                    Button("为这组打分推荐") { scoreSimilarGroup(group) }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Theme.primary)
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
        userTouched = true
        let id = asset.localIdentifier
        if group.wrappedValue.keepIDs.contains(id) {
            if group.wrappedValue.keepIDs.count > 1 { group.keepIDs.wrappedValue.remove(id) }
        } else {
            group.keepIDs.wrappedValue.insert(id)
        }
    }

    // MARK: - 相似组惰性打分

    private func scoreSimilarGroup(_ group: Binding<GroupModel>) {
        guard !group.wrappedValue.isScoring else { return }
        group.isScoring.wrappedValue = true
        Task {
            let (scores, recommended, _) = await service.scoreMembers(
                group.wrappedValue.assets, sizes: group.wrappedValue.sizes, label: "相似组（手动）")
            group.scores.wrappedValue = scores
            group.recommendedID.wrappedValue = recommended
            group.isScoring.wrappedValue = false
        }
    }

    // MARK: - 删除

    private func deleteSelected() async {
        deleting = true
        defer { deleting = false }
        let ids = groups.flatMap(\.deleteIDs)
        let assets = AnalysisService.fetchAssets(ids: ids)
        do {
            try await PhotoDeleter.delete(assets)
            scanner.store.deleteEverywhere(ids: ids)  // embeddings/ocr/quality 三清，不留孤儿行
            userTouched = false
            service.applyDeletions(ids, store: scanner.store)
            rebuildModels()
        } catch {
            // 用户在系统确认框点"取消"是正常路径，静默保留勾选
            if PhotoDeleter.isCancellation(error) { return }
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
        if isKept { return tier == .duplicate ? Theme.success : Theme.warning }
        return tier == .duplicate ? Theme.danger : Theme.muted
    }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomTrailing) {
                thumb
                    .frame(width: 110, height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.gridCell))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.gridCell)
                            .stroke(markColor, lineWidth: 3)
                    )
                    .opacity(isKept ? 1 : (tier == .duplicate ? 0.55 : 0.75))
                Image(systemName: isKept ? "checkmark.circle.fill" : "trash.circle.fill")
                    .foregroundStyle(markColor)
                    .padding(4)
            }
            .overlay(alignment: .topLeading) {
                if isRecommended {
                    Theme.Badge(text: "推荐", systemImage: "star.fill", color: Theme.success)
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
            guard !AutoTest.enabled, image == nil else { return }
            image = await ThumbnailCache.image(for: asset, size: Self.thumbSize)
        }
    }

    private var thumb: some View {
        // 缓存同步命中直接显示（避免滚动闪灰），未命中才异步拉图
        let img = image ?? ThumbnailCache.cached(for: asset, size: Self.thumbSize)
        return Group {
            if let img {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.15)
            }
        }
    }

    private static let thumbSize = CGSize(width: 220, height: 220)
}
