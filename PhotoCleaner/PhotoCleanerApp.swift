import SwiftUI

@main
struct PhotoCleanerApp: App {
    @StateObject private var scanner = LibraryScanner()
    @State private var path = NavigationPath()

    /// 自动化测试模式：启动后自动授权检查 → 小范围扫描 200 张 → 自动进分析页。
    /// 关键节点打 [AutoTest] 日志，供 xcodebuild test 日志采集。
    private let autoTest = ProcessInfo.processInfo.arguments.contains("-autoTest")

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                HomeView()
                    .navigationDestination(for: String.self) { dest in
                        if dest == "results" {
                            ResultsView()
                        } else {
                            EmptyView()
                        }
                    }
            }
            .environmentObject(scanner)
            .task {
                if autoTest { await runAutoTest() }
            }
        }
    }

    private func runAutoTest() async {
        // 防止测试长跑期间屏幕自动锁定（锁屏会导致 XPC 连接断开、测试失败）
        UIApplication.shared.isIdleTimerDisabled = true

        AutoTest.resetLog()
        AutoTest.log("[AutoTest] 进入自测模式")
        scanner.autoTestStatus = "自测模式启动"
        scanner.refreshAuth()
        if scanner.authStatus == .notDetermined {
            AutoTest.log("[AutoTest] 请求相册权限（等待系统弹窗被测试驱动处理）…")
            scanner.autoTestStatus = "等待相册权限"
            await scanner.requestAccess()
        }
        AutoTest.log("[AutoTest] 权限状态: \(scanner.authStatus.rawValue)")
        guard scanner.authStatus == .authorized || scanner.authStatus == .limited else {
            AutoTest.log("[AutoTest] 未获得相册权限，自测终止")
            scanner.autoTestStatus = "失败：未获得相册权限"
            return
        }

        let fullScan = ProcessInfo.processInfo.arguments.contains("-autoTestFull")
        AutoTest.log("[AutoTest] 开始\(fullScan ? "全量" : "小范围")扫描\(fullScan ? "（最近 6 个月）" : "（最近 200 张）")")
        scanner.autoTestStatus = fullScan ? "扫描中（全量）" : "扫描中（最近 200 张）"
        if fullScan { scanner.start() } else { scanner.startTest() }
        // start() 内部异步切状态，先等它进入 busy 再等待结束
        for _ in 0..<50 where !scanner.isBusy {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        while scanner.isBusy {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        let summary = "扫描结束: 已索引=\(scanner.indexedCount), 本次处理=\(scanner.processedThisRun), 失败=\(scanner.failedThisRun), 平均=\(String(format: "%.0f", scanner.avgMs))ms/张"
        AutoTest.log("[AutoTest] \(summary)")
        scanner.autoTestStatus = summary

        guard scanner.indexedCount >= 2 else {
            AutoTest.log("[AutoTest] 索引数不足 2 张，不进分析页")
            scanner.autoTestStatus += "｜索引不足，未进分析页"
            return
        }

        // 语义搜图自测：3 个固定 query，Top 5 asset id + 分数写进 autotest.log
        await runSearchSelfTest()

        // 废片候选统计（默认阈值 0.6，loadCandidates 内部会打 [Junk] 分布日志）
        let store = scanner.store
        _ = await Task.detached(priority: .utility) {
            JunkReviewView.loadCandidates(store: store, threshold: 0.6)
        }.value

        AutoTest.log("[AutoTest] 进入分析页")
        scanner.autoTestStatus += "｜已进入分析页"
        path.append("results")
    }

    /// 语义搜图自测：固定 query 跑 Top 5，验证文本→向量→检索链路（含 OCR 关键词通道）。
    private func runSearchSelfTest() async {
        let idx = SemanticSearch.VectorIndex.shared
        idx.reloadIfNeeded(store: scanner.store)
        let cov = scanner.store.ocrCoverage()
        AutoTest.log("[AutoTest] ocr覆盖=\(cov.total)/\(scanner.store.count())（有文本 \(cov.withText) 条）")
        for q in ["猫", "风景", "文档", "http"] {
            do {
                let vec = try await scanner.engine.embedText(q)
                let top = idx.hybridTopK(queryVector: vec, queryText: q, k: 5)
                let desc = top.map {
                    "\($0.id)#\(String(format: "%.3f", $0.score))\($0.keywordMatched ? "[文]" : "")"
                }.joined(separator: ",")
                AutoTest.log("[AutoTest] query=\"\(q)\" top5=\(desc)")
            } catch {
                AutoTest.log("[AutoTest] query=\"\(q)\" 失败: \(error.localizedDescription)")
            }
        }
    }
}
