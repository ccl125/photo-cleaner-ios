import Photos
import SwiftUI

/// 首页：权限、扫描进度、统计、入口。
struct HomeView: View {
    @EnvironmentObject private var scanner: LibraryScanner
    @State private var cleanup: CleanupScanner.Summary?
    @AppStorage("fpThresholdV2") private var fpThresholdV2: Double = 0.15
    @AppStorage("junkThreshold") private var junkThreshold: Double = 0.6
    @State private var searchText = ""
    @State private var junkCount: Int?

    var body: some View {
        VStack(spacing: 24) {
            Text("PhotoCleaner")
                .font(.largeTitle.bold())

            if !scanner.autoTestStatus.isEmpty {
                Text(scanner.autoTestStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("autoTestStatus")
            }

            TextField("语义搜图：试试「猫」「风景」「文档」…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .accessibilityIdentifier("searchField")

            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                authSection
                statsSection
                cleanupSection
                junkSection
                scanSection
                labSection

                Spacer()
            } else {
                SearchResultsGrid(query: searchText)
            }
        }
        .padding()
        .navigationBarHidden(true)
        .onAppear {
            scanner.refreshAuth()
            scanner.refreshCounts()
        }
        .task(id: scanner.authStatus) { await loadCleanupSummary() }
        .task(id: junkThreshold) { await loadJunkCount() }
        .task(id: scanner.indexedCount) { await loadJunkCount() }
    }

    private func loadJunkCount() async {
        guard scanner.authStatus == .authorized || scanner.authStatus == .limited else { return }
        let store = scanner.store
        let thr = junkThreshold
        junkCount = await Task.detached(priority: .utility) {
            JunkReviewView.loadCandidates(store: store, threshold: thr).list.count
        }.value
    }

    private func loadCleanupSummary() async {
        guard scanner.authStatus == .authorized || scanner.authStatus == .limited else { return }
        cleanup = await Task.detached(priority: .utility) {
            CleanupScanner.summary()
        }.value
    }

    // MARK: - 权限

    @ViewBuilder
    private var authSection: some View {
        switch scanner.authStatus {
        case .authorized:
            Label("已授权访问全部照片", systemImage: "checkmark.shield")
                .foregroundStyle(.green)
        case .limited:
            Label("已授权访问部分照片（Limited 模式）", systemImage: "checkmark.shield")
                .foregroundStyle(.orange)
        case .denied, .restricted:
            VStack(spacing: 8) {
                Label("未获得照片访问权限", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.red)
                Button("去系统设置开启") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        default:
            Button("授权访问照片库") {
                Task { await scanner.requestAccess() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - 统计

    private var statsSection: some View {
        VStack(spacing: 8) {
            statRow("最近 6 个月图片", "\(scanner.totalAssets) 张")
            statRow("已索引", "\(scanner.indexedCount) 张")
            if scanner.avgMs > 0 {
                statRow("单张耗时（上一张 / 平均）",
                        String(format: "%.0f ms / %.0f ms", scanner.lastImageMs, scanner.avgMs))
            }
            if scanner.failedThisRun > 0 {
                statRow("本次失败（iCloud 拉取失败等）", "\(scanner.failedThisRun) 张")
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
    }

    // MARK: - 清理清单

    @ViewBuilder
    private var cleanupSection: some View {
        if scanner.authStatus == .authorized || scanner.authStatus == .limited {
            VStack(spacing: 8) {
                if let cleanup {
                    statRow("截图 / 录屏 / 大视频",
                            "\(cleanup.screenshotCount) 张 / \(cleanup.recordingCount) 个 / \(CleanupListView.formatBytes(cleanup.largeVideoBytes))")
                } else {
                    statRow("截图 / 录屏 / 大视频", "统计中…")
                }
                NavigationLink("清理清单（截图 · 录屏 · 大视频）→") {
                    CleanupListView()
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - 废片清理

    @ViewBuilder
    private var junkSection: some View {
        if scanner.authStatus == .authorized || scanner.authStatus == .limited {
            NavigationLink {
                JunkReviewView(threshold: junkThreshold)
            } label: {
                if let junkCount {
                    Text("废片清理（\(junkCount) 张待审）→")
                } else {
                    Text("废片清理（统计中…）")
                }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("junkEntry")
        }
    }

    // MARK: - 扫描控制

    @ViewBuilder
    private var scanSection: some View {
        switch scanner.state {
        case .idle:
            Button("开始扫描") { scanner.start() }
                .buttonStyle(.borderedProminent)
                .disabled(scanner.authStatus != .authorized && scanner.authStatus != .limited)
                .accessibilityIdentifier("scanButton")
            Button("小范围测试（最近 200 张）") { scanner.startTest() }
                .buttonStyle(.bordered)
                .disabled(scanner.authStatus != .authorized && scanner.authStatus != .limited)
                .accessibilityIdentifier("testScanButton")
            // 已有索引就随时可进分析页，不必先扫描
            if scanner.indexedCount >= 2 { analyzeButton }
        case .preparingModels:
            Label("正在加载模型（首次需编译，约 1 分钟）…", systemImage: "cpu")
            ProgressView()
        case .running:
            ProgressView(value: scanner.progress) {
                Text("扫描中 \(scanner.indexedCount + scanner.failedThisRun) / \(scanner.totalAssets)")
            }
            Button("暂停") { scanner.pause() }
                .buttonStyle(.bordered)
        case .paused:
            Text("已暂停（\(scanner.indexedCount)/\(scanner.totalAssets)）")
            HStack {
                Button("继续") { scanner.resume() }.buttonStyle(.borderedProminent)
                if scanner.indexedCount >= 2 { analyzeButton }
            }
        case .finished:
            Label("索引完成：\(scanner.indexedCount) 张", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
            if scanner.indexedCount >= 2 { analyzeButton }
            Button("重新扫描增量") { scanner.start() }
                .buttonStyle(.bordered)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .font(.footnote)
            Button("重试") { scanner.start() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - 实验室（阈值调节）

    private var labSection: some View {
        VStack(spacing: 6) {
            HStack {
                Text("重复判定严格度").foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f", fpThresholdV2)).monospacedDigit()
            }
            .font(.subheadline)
            Slider(value: $fpThresholdV2, in: 0.05...0.60, step: 0.05)
            Text("越小越严格：只有像素级几乎一样的照片才会进入删除建议")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider().padding(.vertical, 4)

            HStack {
                Text("废片嫌疑阈值").foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f", junkThreshold)).monospacedDigit()
            }
            .font(.subheadline)
            Slider(value: $junkThreshold, in: 0.3...0.9, step: 0.05)
            Text("越高越保守：只有废片特征很明显的照片才进入速审队列")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var analyzeButton: some View {
        NavigationLink("分析相似照片 →") {
            ResultsView()
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("analyzeLink")
    }
}
