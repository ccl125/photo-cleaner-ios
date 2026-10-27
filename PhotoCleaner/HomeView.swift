import Photos
import SwiftUI

/// 清理 Tab 首页：顶部真实相册/索引摘要 + 一句话状态，下面四个任务模块
///（扫描 / 相似照片分组 / 废片速审 / 清理清单）。实验室滑块在设置 Tab。
/// 状态覆盖：未授权 / 已授权未索引 / 扫描中 / 已完成 / 出错。
struct HomeView: View {
    @EnvironmentObject private var scanner: LibraryScanner
    @AppStorage("junkThreshold") private var junkThreshold: Double = 0.6
    @AppStorage("autoIndexEnabled") private var autoIndexEnabled = true
    @State private var cleanup: CleanupScanner.Summary?
    @State private var junkCount: Int?
    @State private var didAutoStart = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                if !scanner.autoTestStatus.isEmpty {
                    Text(scanner.autoTestStatus)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .accessibilityIdentifier("autoTestStatus")
                }

                summaryCard
                scanModule

                if scanner.authStatus == .authorized || scanner.authStatus == .limited {
                    analyzeModule
                    junkModule
                    cleanupModule
                }
            }
            .padding(Theme.Spacing.md)
        }
        .background(Theme.background)
        .navigationTitle("清理")
        .onAppear {
            scanner.refreshAuth()
            scanner.refreshCounts()
        }
        .task(id: scanner.authStatus) { await loadCleanupSummary() }
        .task(id: junkThreshold) { await loadJunkCount() }
        .task(id: scanner.indexedCount) { await loadJunkCount() }
        .task { await autoIndexIfNeeded() }
        .onChange(of: scanner.state) { _, newState in
            // 扫描完成 → 自动触发相似分组分析（缓存感知；自测模式走自己的流程）
            if case .finished = newState, scanner.indexedCount >= 2, !AutoTest.enabled {
                Task { await AnalysisService.shared.analyze(scanner: scanner) }
            }
        }
    }

    /// 自动索引：启动后延迟 2 秒（避开启动渲染），有未索引照片则自动增量扫描。
    /// 每次冷启动最多自动触发一次；自测模式跳过（它有自己的扫描流程）。
    private func autoIndexIfNeeded() async {
        guard autoIndexEnabled, !AutoTest.enabled, !didAutoStart else { return }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled, !didAutoStart else { return }
        didAutoStart = true
        scanner.refreshAuth()
        scanner.refreshCounts()
        guard hasAccess, scanner.state == .idle else { return }
        let pending = scanner.totalAssets - scanner.indexedCount
        guard pending > 0 else {
            AutoTest.log("[Auto] 无未索引照片，跳过自动索引")
            return
        }
        AutoTest.log("[Auto] 自动索引启动：待索引约 \(pending) 张")
        scanner.start()
    }

    private var hasAccess: Bool {
        scanner.authStatus == .authorized || scanner.authStatus == .limited
    }

    private func loadJunkCount() async {
        guard hasAccess else { return }
        let store = scanner.store
        let thr = junkThreshold
        junkCount = await Task.detached(priority: .utility) {
            JunkReviewView.loadCandidates(store: store, threshold: thr).list.count
        }.value
    }

    private func loadCleanupSummary() async {
        guard hasAccess else { return }
        cleanup = await Task.detached(priority: .utility) {
            CleanupScanner.summary()
        }.value
    }

    // MARK: - 顶部摘要（真实数据 + 一句话状态）

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("相册索引")
                .themeSectionHeader()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(scanner.indexedCount) 张已索引")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Text("最近 6 个月共 \(scanner.totalAssets) 张")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Image(systemName: summaryIcon)
                    .font(.title2)
                    .foregroundStyle(summaryIconColor)
            }
            Text(statusSentence)
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
            if scanner.state == .running || scanner.state == .paused {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: scanner.progress)
                        .tint(Theme.primary)
                    Text("本次 \(scanner.processedThisRun + scanner.failedThisRun) / \(scanner.pendingTotalCount) 张")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .themeCard()
    }

    private var summaryIcon: String {
        switch scanner.state {
        case .running, .preparingModels: return "arrow.triangle.2.circlepath"
        case .finished: return "checkmark.shield"
        case .failed: return "exclamationmark.triangle"
        default: return hasAccess ? "photo.on.rectangle" : "lock.shield"
        }
    }

    private var summaryIconColor: Color {
        switch scanner.state {
        case .finished: return Theme.success
        case .failed: return Theme.danger
        case .running, .preparingModels: return Theme.primary
        default: return Theme.muted
        }
    }

    private var statusSentence: String {
        switch scanner.authStatus {
        case .denied, .restricted:
            return "没有照片访问权限，无法建立索引。"
        case .notDetermined:
            return "授权后即可开始。照片全程不出这台设备。"
        default:
            break
        }
        switch scanner.state {
        case .preparingModels: return "正在加载本地模型（首次需编译，约 1 分钟）…"
        case .running: return "正在索引照片：embedding + OCR + 质量信号。"
        case .paused: return "扫描已暂停，进度已保存，随时继续。"
        case .finished: return "索引就绪，可以分析分组、审废片或清理清单。"
        case .failed: return "扫描出错，可重试，已索引的进度不会丢。"
        case .idle:
            return scanner.indexedCount > 0 ? "索引就绪，可以开始分析。" : "还没有索引。先扫描照片建立本地向量索引。"
        }
    }

    // MARK: - 任务模块 1：扫描

    @ViewBuilder
    private var scanModule: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label("建立索引", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
                .foregroundStyle(Theme.ink)
            moduleBody
        }
        .themeCard()
    }

    @ViewBuilder
    private var moduleBody: some View {
        switch scanner.authStatus {
        case .denied, .restricted:
            Text("需要照片访问权限才能建立索引。")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
            Button("去系统设置开启") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .primaryButton()
        case .notDetermined:
            Text("扫描在本地为每张照片算向量、OCR 文字和质量信号，用于后续所有清理判定。")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
            Button("授权访问照片库") {
                Task { await scanner.requestAccess() }
            }
            .primaryButton()
        default:
            scanControls
        }
    }

    @ViewBuilder
    private var scanControls: some View {
        switch scanner.state {
        case .idle:
            Button(scanner.indexedCount > 0 ? "继续扫描（增量）" : "开始扫描") { scanner.start() }
                .primaryButton()
                .accessibilityIdentifier("scanButton")
            Button("小范围测试（最近 200 张）") { scanner.startTest() }
                .secondaryButton()
                .accessibilityIdentifier("testScanButton")
        case .preparingModels:
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView()
                Text("正在加载模型…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            }
        case .running:
            ProgressView(value: scanner.progress) {
                Text("扫描中 \(scanner.processedThisRun + scanner.failedThisRun) / \(scanner.pendingTotalCount)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
            }
            if scanner.avgMs > 0 {
                Text(String(format: "单张 %.0f ms · 本次失败 %d 张", scanner.avgMs, scanner.failedThisRun))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            Button("暂停") { scanner.pause() }
                .secondaryButton()
        case .paused:
            Text("已暂停（\(scanner.indexedCount)/\(scanner.totalAssets)）")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
            Button("继续") { scanner.resume() }
                .primaryButton()
        case .finished:
            Label("索引完成：\(scanner.indexedCount) 张", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
                .font(.subheadline)
            Button("扫描新增照片") { scanner.start() }
                .secondaryButton()
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon")
                .foregroundStyle(Theme.danger)
                .font(.footnote)
            Button("重试") { scanner.start() }
                .primaryButton()
        }
    }

    // MARK: - 任务模块 2-4

    private var analyzeModule: some View {
        NavigationLink {
            ResultsView()
        } label: {
            TaskModuleLabel(
                icon: "square.grid.2x2", tint: Theme.primary,
                title: "相似照片分组",
                subtitle: scanner.indexedCount >= 2
                    ? "重复组像素级复核 + 相似组聚类"
                    : "需要先建立索引",
                trailing: scanner.indexedCount >= 2 ? "\(scanner.indexedCount) 张可分析" : nil
            )
        }
        .disabled(scanner.indexedCount < 2)
        .accessibilityIdentifier("analyzeLink")
    }

    private var junkModule: some View {
        NavigationLink {
            JunkReviewView(threshold: junkThreshold)
        } label: {
            TaskModuleLabel(
                icon: "hand.thumbsdown", tint: Theme.danger,
                title: "废片速审",
                subtitle: "模糊 / 黑白帧 / 闭眼，左滑删右滑留",
                trailing: junkCount.map { "\($0) 张待审" }
            )
        }
        .accessibilityIdentifier("junkEntry")
    }

    private var cleanupModule: some View {
        NavigationLink {
            CleanupListView()
        } label: {
            TaskModuleLabel(
                icon: "list.bullet.rectangle", tint: Theme.muted,
                title: "清理清单",
                subtitle: "截图 · 录屏 · 大视频",
                trailing: cleanup.map {
                    "\($0.screenshotCount)/\($0.recordingCount)/\(CleanupListView.formatBytes($0.largeVideoBytes))"
                }
            )
        }
    }
}

/// 任务模块标签：图标 + 标题 + 一句说明 + 右侧真实计数，统一卡片样式。
private struct TaskModuleLabel: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    var trailing: String?

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
        .frame(minHeight: 44)
        .themeCard()
    }
}
