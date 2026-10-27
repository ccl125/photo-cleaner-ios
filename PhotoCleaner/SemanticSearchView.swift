import Photos
import SwiftUI
import UIKit

/// 语义搜索结果网格：300ms 防抖（task(id:) + sleep + 取消检查），
/// 文本向量化后全库 cosine Top 50，缩略图 + 分数角标，点击全屏查看。
struct SearchResultsGrid: View {
    let query: String
    @EnvironmentObject private var scanner: LibraryScanner

    @State private var results: [(asset: PHAsset, score: Float, keywordMatched: Bool)] = []
    @State private var searching = false
    @State private var errorMessage: String?
    @State private var selected: SelectedAsset?

    /// sheet(item:) 需要 Identifiable，PHAsset 不自己扩展（新 SDK 可能已内置）。
    private struct SelectedAsset: Identifiable {
        let asset: PHAsset
        var id: String { asset.localIdentifier }
    }

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .padding()
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(results, id: \.asset.localIdentifier) { item in
                    SearchHitCell(asset: item.asset, score: item.score,
                                  keywordMatched: item.keywordMatched) {
                        selected = SelectedAsset(asset: item.asset)
                    }
                }
            }
            .padding(4)
            if searching {
                ProgressView("搜索中…").padding()
            } else if errorMessage == nil && results.isEmpty {
                Text("没有结果").foregroundStyle(.secondary).padding()
            }
        }
        .sheet(item: $selected) { sel in
            FullscreenPhotoView(asset: sel.asset)
        }
        .task(id: query) { await runSearch() }
    }

    private func runSearch() async {
        // 300ms 防抖
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; errorMessage = nil; return }

        searching = true
        errorMessage = nil
        defer { searching = false }
        do {
            let vec = try await scanner.engine.embedText(q)
            let store = scanner.store
            let hits = await Task.detached(priority: .userInitiated) {
                let idx = SemanticSearch.VectorIndex.shared
                idx.reloadIfNeeded(store: store)
                return idx.hybridTopK(queryVector: vec, queryText: q, k: 50)
            }.value
            guard !Task.isCancelled else { return }
            let assets = fetchAssets(ids: hits.map(\.id))
            results = hits.compactMap { hit in
                assets[hit.id].map { (asset: $0, score: hit.score, keywordMatched: hit.keywordMatched) }
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "搜索失败：\(error.localizedDescription)"
        }
    }

    private func fetchAssets(ids: [String]) -> [String: PHAsset] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byID: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        return byID
    }
}

/// 搜索结果单格：缩略图 + cosine 分数角标 + 关键词命中"文字"徽标。
private struct SearchHitCell: View {
    let asset: PHAsset
    let score: Float
    let keywordMatched: Bool
    let onTap: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Button(action: onTap) {
            thumb
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.gridCell))
                .overlay(alignment: .bottomTrailing) {
                    Text(String(format: "%.3f", score))
                        .font(.caption2.monospacedDigit().bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(4)
                }
                .overlay(alignment: .topLeading) {
                    if keywordMatched {
                        Theme.Badge(text: "文字", systemImage: "text.viewfinder", color: Theme.primary)
                            .padding(4)
                    }
                }
        }
        .buttonStyle(.plain)
        .task(id: asset.localIdentifier) {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                targetSize: CGSize(width: 240, height: 240),
                contentMode: .aspectFill,
                options: opts
            ) { image, _ in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: image)
            }
        }
    }
}

/// 全屏查看单张照片。
struct FullscreenPhotoView: View {
    let asset: PHAsset
    @State private var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white)
                    .padding()
            }
        }
        .task(id: asset.localIdentifier) {
            image = await Self.loadLarge(asset: asset)
        }
    }

    static func loadLarge(asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { cont in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = true
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 1600, height: 1600),
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
