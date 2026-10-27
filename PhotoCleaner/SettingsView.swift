import SwiftUI

/// 设置 Tab：实验室阈值、索引/模型版本信息、隐私说明、日志自测说明。
struct SettingsView: View {
    @EnvironmentObject private var scanner: LibraryScanner
    @AppStorage("fpThresholdV2") private var fpThresholdV2: Double = 0.15
    @AppStorage("junkThreshold") private var junkThreshold: Double = 0.6
    @AppStorage("autoIndexEnabled") private var autoIndexEnabled = true
    @AppStorage("backgroundIndexEnabled") private var backgroundIndexEnabled = true
    @State private var modelVersion: String = "—"

    var body: some View {
        List {
            Section {
                Toggle("自动索引", isOn: $autoIndexEnabled)
                    .tint(Theme.primary)
                Text("启动后若有未索引照片，自动开始增量扫描；扫描完成自动刷新相似分组。")
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
                Toggle("后台自动索引（充电时）", isOn: $backgroundIndexEnabled)
                    .tint(Theme.primary)
                    .onChange(of: backgroundIndexEnabled) { _, on in
                        if on {
                            BackgroundIndexer.shared.scheduleNextIfEnabled()
                        } else {
                            BackgroundIndexer.shared.cancel()
                        }
                    }
                Text("退到后台或锁屏后，系统会在充电时自动继续索引，无需打开 App。")
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
            } header: {
                Text("自动化").themeSectionHeader()
            }

            Section {
                LabeledSlider(
                    title: "重复判定严格度",
                    value: $fpThresholdV2, range: 0.05...0.60, step: 0.05,
                    footnote: "越小越严格：只有像素级几乎一样的照片才会进入删除建议"
                )
                LabeledSlider(
                    title: "废片嫌疑阈值",
                    value: $junkThreshold, range: 0.3...0.9, step: 0.05,
                    footnote: "越高越保守：只有废片特征很明显的照片才进入速审队列"
                )
            } header: {
                Text("实验室").themeSectionHeader()
            }

            Section {
                infoRow("模型", "EmbeddingGemma 2（Core ML，vision_70）")
                infoRow("向量维度", "\(EmbeddingEngine.outputDim) 维（MRL 截断）")
                infoRow("索引版本", modelVersion)
                infoRow("已索引", "\(scanner.indexedCount) 张")
            } header: {
                Text("模型与索引").themeSectionHeader()
            }

            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Label("照片不出这台设备", systemImage: "lock.shield")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.ink)
                    Text("所有向量、OCR 文字和质量信号都在本机计算并只存在本机。没有任何服务器，不上传照片，删除始终经过系统确认框并先进入“最近删除”。")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                }
                .padding(.vertical, Theme.Spacing.xs)
            } header: {
                Text("隐私").themeSectionHeader()
            }

            Section {
                DisclosureGroup("日志与自测说明") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("以 -autoTest 启动会进入自测模式：自动小范围扫描、跑固定搜索词、进分析页，并在 Documents/autotest.log 落全量日志（[Engine]/[Scanner]/[Analyze]/[AutoTest]）。")
                        Text("向量库位于 Documents/embeddings.sqlite；模型编译缓存位于 Documents/models-compiled/，删除 App 会一并清除。")
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, Theme.Spacing.xs)
                }
                .foregroundStyle(Theme.ink)
            }
        }
        .navigationTitle("设置")
        .task {
            try? scanner.store.open()
            modelVersion = scanner.store.metaValue("modelVersion") ?? "未建立"
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.muted)
            Spacer()
            Text(value).foregroundStyle(Theme.ink).monospacedDigit()
        }
        .font(.subheadline)
    }
}

/// 实验室滑块：标题 + 当前值 + 滑块 + 一行说明。
private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let footnote: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text(title).foregroundStyle(Theme.ink)
                Spacer()
                Text(String(format: "%.2f", value))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            .font(.subheadline)
            Slider(value: $value, in: range, step: step)
                .tint(Theme.primary)
            Text(footnote)
                .font(.caption2)
                .foregroundStyle(Theme.muted)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}
