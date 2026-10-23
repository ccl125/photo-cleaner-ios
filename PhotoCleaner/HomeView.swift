import Photos
import SwiftUI

/// 首页：权限、扫描进度、统计、入口。
struct HomeView: View {
    @EnvironmentObject private var scanner: LibraryScanner
    @State private var cleanup: CleanupScanner.Summary?

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

            authSection
            statsSection
            cleanupSection
            scanSection

            Spacer()
        }
        .padding()
        .navigationBarHidden(true)
        .onAppear { scanner.refreshAuth() }
        .task(id: scanner.authStatus) { await loadCleanupSummary() }
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

    private var analyzeButton: some View {
        NavigationLink("分析相似照片 →") {
            ResultsView()
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("analyzeLink")
    }
}
