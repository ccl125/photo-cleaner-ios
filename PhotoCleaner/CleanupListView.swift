import Photos
import SwiftUI
import UIKit

/// 清理清单：截图 / 录屏 / 大视频（Top 50），点击进入网格勾选批量删除。
struct CleanupListView: View {

    struct Category: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let assets: [PHAsset]
        let bytes: Int64
    }

    @State private var categories: [Category] = []
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView("正在统计…")
            } else {
                List(categories) { cat in
                    NavigationLink {
                        CleanupGridView(title: cat.title, assets: cat.assets)
                    } label: {
                        Label(cat.title, systemImage: cat.systemImage)
                            .foregroundStyle(Theme.ink)
                            .tint(Theme.primary)
                        Spacer()
                        Text("\(cat.assets.count) 项 · \(Self.formatBytes(cat.bytes))")
                            .foregroundStyle(Theme.muted)
                            .font(.subheadline)
                    }
                    .frame(minHeight: 44)
                }
            }
        }
        .navigationTitle("清理清单")
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let cats = await Task.detached(priority: .userInitiated) {
            let shots = CleanupScanner.screenshots()
            let recs = CleanupScanner.screenRecordings()
            let videos = CleanupScanner.largeVideos()
            return [
                Category(id: "screenshots", title: "截图", systemImage: "camera.viewfinder",
                         assets: shots, bytes: CleanupScanner.totalBytes(of: shots)),
                Category(id: "recordings", title: "录屏", systemImage: "record.circle",
                         assets: recs, bytes: CleanupScanner.totalBytes(of: recs)),
                Category(id: "videos", title: "大视频 Top 50", systemImage: "video.fill",
                         assets: videos, bytes: CleanupScanner.totalBytes(of: videos)),
            ]
        }.value
        categories = cats
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// 某一类的网格勾选删除页。默认不选，提供全选；删除复用 PhotoDeleter。
struct CleanupGridView: View {
    let title: String
    @State var assets: [PHAsset]
    @State private var selected: Set<String> = []
    @State private var showConfirm = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var scanner: LibraryScanner

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    private var selectedAssets: [PHAsset] {
        assets.filter { selected.contains($0.localIdentifier) }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    CleanupCell(asset: asset, isSelected: selected.contains(asset.localIdentifier)) {
                        if selected.contains(asset.localIdentifier) {
                            selected.remove(asset.localIdentifier)
                        } else {
                            selected.insert(asset.localIdentifier)
                        }
                    }
                }
            }
            .padding(4)
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selected.count == assets.count ? "取消全选" : "全选") {
                    selected = selected.count == assets.count
                        ? [] : Set(assets.map(\.localIdentifier))
                }
                .tint(Theme.primary)
            }
            ToolbarItem(placement: .bottomBar) {
                Button(role: .destructive) { showConfirm = true } label: {
                    Label("删除选中 \(selected.count) 项（约 \(ResultsView.formatBytes(CleanupScanner.totalBytes(of: selectedAssets)))）",
                          systemImage: "trash")
                }
                .tint(Theme.danger)
                .disabled(selected.isEmpty)
            }
        }
        .alert("确认删除？", isPresented: $showConfirm) {
            Button("删除", role: .destructive) { Task { await deleteSelected() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从相册删除 \(selected.count) 项，系统会再次向你确认。")
        }
        .alert("出错了", isPresented: .constant(errorMessage != nil)) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func deleteSelected() async {
        let victims = selectedAssets
        do {
            try await PhotoDeleter.delete(victims)
            let deleted = Set(victims.map(\.localIdentifier))
            // 清索引（截图也可能有向量）+ 同步分析缓存
            scanner.store.deleteEverywhere(ids: Array(deleted))
            AnalysisService.shared.applyDeletions(Array(deleted), store: scanner.store)
            assets.removeAll { deleted.contains($0.localIdentifier) }
            selected = []
            if assets.isEmpty { dismiss() }
        } catch {
            // 用户在系统确认框点"取消"是正常路径，静默保留勾选
            if PhotoDeleter.isCancellation(error) { return }
            errorMessage = error.localizedDescription
        }
    }
}

/// 清理网格的单格：缩略图（视频带时长/大小角标）+ 选中勾。
private struct CleanupCell: View {
    let asset: PHAsset
    let isSelected: Bool
    let onTap: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomTrailing) {
                thumb
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.gridCell))
                    .opacity(isSelected ? 0.6 : 1)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Theme.success : .white)
                            .shadow(radius: 1)
                            .padding(6)
                    }
                if asset.mediaType == .video {
                    Text(ResultsView.formatBytes(CleanupScanner.fileSize(of: asset)))
                        .font(.caption2.bold())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: asset.localIdentifier) {
            guard image == nil else { return }
            image = await ThumbnailCache.image(for: asset, size: Self.thumbSize)
        }
    }

    private var thumb: some View {
        let img = image ?? ThumbnailCache.cached(for: asset, size: Self.thumbSize)
        return Group {
            if let img {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.15)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let thumbSize = CGSize(width: 240, height: 240)
}
