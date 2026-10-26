# PhotoCleaner 架构文档

> 端侧 AI 相册清理：SwiftUI + PhotoKit + EmbeddingGemma 2（Core ML）。
> 本文基于当前代码实现撰写（`PhotoCleaner/`），原型验证数据见 `../photo-cleaner-prototype/RESULTS.md`。

## 1. 架构分层

```
┌─────────────────────────────────────────────────────────────────────┐
│ 行动层                                                               │
│  ResultsView（分组浏览/勾选/打分）  CleanupListView（清理清单）        │
│  PhotoDeleter ── PHPhotoLibrary.performChanges（系统确认框）          │
├─────────────────────────────────────────────────────────────────────┤
│ 判定层                                                               │
│  DedupAnalyzer（星型聚类，双阈值分档）                                 │
│  FeaturePrintVerifier（VNFeaturePrint 像素级复核）                     │
│  QualityScorer（组内质量打分，推荐保留项）                              │
│  ※ 未通过验证的成员一律降级到相似组（保守原则）                          │
├─────────────────────────────────────────────────────────────────────┤
│ 分组/搜索                                                            │
│  DedupAnalyzer.findGroups（分块 sgemm 度数统计 + sgemv 锚点行重算）    │
│  SemanticSearch.VectorIndex（内存向量矩阵 + OCR 关键词混合检索）       │
├─────────────────────────────────────────────────────────────────────┤
│ 存储层                                                               │
│  EmbeddingStore（SQLite3 C API，零依赖）                              │
│    embeddings: id → 256d Float32 blob（1KB/张）                      │
│    ocr:        id → 识别文本（done_at 兼作"已跑过"标记）              │
│    meta:       modelVersion = eg2-256d-v1（索引格式版本）             │
├─────────────────────────────────────────────────────────────────────┤
│ 索引层                                                               │
│  LibraryScanner（PhotoKit 拉图 512px，断点续跑，暂停/继续，12s 超时）   │
│  EmbeddingEngine（vision_70 → embed_128 → MRL 256d → L2 归一化）     │
│  OcrEngine（VNRecognizeTextRequest fast 档，中英文）                  │
│  ModelManager（mlpackage → 编译缓存 Documents/models-compiled/）      │
├─────────────────────────────────────────────────────────────────────┤
│ 数据源                                                               │
│  系统相册（PhotoKit，最近 6 个月图片；支持 Limited 授权）              │
│  模型资产（EmbeddingGemma2Vision/Text.mlpackage、fp16 特殊 token/     │
│           位置表、int8 量化词表、tokenizer.json）                     │
└─────────────────────────────────────────────────────────────────────┘
```

数据流向：相册 → 索引层（embedding + OCR 落 SQLite）→ 存储层 → 分组/搜索（纯内存向量计算）→ 判定层（多级验证 + 打分）→ 行动层（用户确认后系统弹窗删除，进"最近删除"）。

## 2. 判定管线详解

判定管线分三级，逐级收紧，删除建议只给通过全部验证的照片。

### 2.1 第一级：语义向量分组（DedupAnalyzer）

全量向量两两 cosine（向量已 L2 归一化，点积即 cosine）：

- **Pass 1**：分块 `cblas_sgemm`（256 行查询块 × 全库矩阵），只统计每个向量在两档上的度数，内存 O(256×n)。
- **Pass 2**：按度数降序选锚点，`cblas_sgemv` 按需重算锚点与全库的相似度行，做**锚点星型聚类**。

**双阈值分档（边集互斥）**：

| 档位 | cosine 区间 | 语义 |
|---|---|---|
| 重复组 duplicate | > 0.97 | 近重复，可安全建议删除 |
| 相似组 similar | 0.90 – 0.97 | 同主题/连拍，只浏览不自动建议删除 |

已进入重复组的照片不再参与相似组。

#### 为什么不用 union-find：3357 张假组的教训

初版用 union-find 连通分量分组。问题在于相似度关系**不具备传递性**：连拍序列 A~B、B~C、C~D…… 每对相邻都过阈值，链式传递会把几千张互不相似的照片串成一个组——真机实测 4,594 张里最大组 **3,357 张**，显然不可用。

数学上这不可避免：若相邻两对 cosine 都是 c，则首尾 cosine 最高只能压到 2c²−1（c=0.98 时为 0.92），链条越长，首尾越无关，union-find 照样合并。

星型聚类只允许**直接与锚点相似**的照片入组，组内凝聚度有锚点背书（实测组内 min ≥ 0.86）。上面的链式场景下，星型聚类会把链条切成"以高度数节点为中心的若干小星"，而不是一个巨组。该场景已由 `PhotoCleanerTests/DedupAnalyzerTests` 的链式用例固化为回归测试。

### 2.2 第二级：像素级复核（FeaturePrintVerifier）

语义向量分不清"同一张照片的变体"和"同人同景不同姿势"。对重复组候选，用 `VNGenerateImageFeaturePrintRequest` 算组内成员与锚点（质量打分推荐的保留项）的特征指纹距离。校准数据（代码注释）：精确缩放变体 0.14，连拍位移 0.21，重度压缩 0.33–0.48。

**三重重复验证，全部满足才留在重复组**（`ResultsView` 内判定）：

1. **指纹距离 ≤ 阈值**（默认 0.15，首页"实验室"滑块 0.05–0.60 可调，存 `UserDefaults.fpThresholdV2`）。真机教训：阈值 0.20 时 256px 缩略图会把"同场景不同构图"误判为重复（人眼能分辨），所以默认压到 0.15。
2. **像素宽高完全相同**：不同构图/裁剪的尺寸必不同。
3. **拍摄时间相差 ≤ 10 分钟**：同一拍摄现场（无时间信息时不阻断）。

### 2.3 保守原则：未验证一律降级

这是判定管线最重要的安全约束：

- 未参与打分/验证的成员（大组截断、拉图失败、指纹缺失记 `.infinity`）**必须降级**，绝不能带着删除建议留在重复组；
- 三重条件任一不满足 → 降级到相似组（与锚点另组一个相似组，只浏览）；
- 验证后重复组不足 2 张 → 整组降为相似组。

效果：删除建议的精度优先于召回——宁可漏删，不可错删。

### 2.4 组内质量打分（QualityScorer）

只对组内成员（通常 2–10 张）打分，不做全库打分，全部端侧、零新模型：

| 维度 | 权重 | 方法 |
|---|---|---|
| 模糊 | 40% | Laplacian 方差（256px 灰度 + vImage PlanarF 卷积不截断），log10 后组内 min-max 归一 |
| 人脸 | 30% | `VNDetectFaceCaptureQualityRequest` 取最高值，无人脸记中性 0.5 |
| 分辨率 | 30% | pixelWidth×pixelHeight 按组内最大值归一 |

综合分 = 0.4×模糊 + 0.3×人脸 + 0.3×分辨率，最高者为推荐保留项（ResultsView 打"推荐"徽标）。

## 3. 关键 ADR

### ADR-1：MRL 截断到 256 维

EmbeddingGemma 2 输出 768 维，支持 Matryoshka（MRL）截断：取前 N 维 + 重新 L2 归一化。原型实测（`bench_mrl.py`）：

| 维度 | 分离间隔 | 阈值 0.93 完全分离 | 排序一致性 τ vs 768d | 每向量(fp32) |
|---|---|---|---|---|
| 768 | +0.071 | ✅ | 1.0 | 3 KB |
| **256** | **+0.062** | **✅** | **0.929** | **1 KB** |
| 128 | +0.046 | ❌（无关对越阈） | 0.751 | 0.5 KB |

**决策：生产用 256 维。** 间隔仍为正、阈值完全可分、排序一致性 93%，存储和检索成本降为 1/3。128 维出现"无关→相似"的分类翻转，与官方"128d 多模态质量明显下降"的警告一致，弃用。

### ADR-2：模型选型 EmbeddingGemma 2，而非 MobileCLIP

| 候选 | License | 结论 |
|---|---|---|
| **EmbeddingGemma 2**（google，740M 多模态） | **Apache 2.0** | ✅ 可自由商用/分发，且有现成的 FluidInference Core ML 端口（fp16，已修复 RMSNorm 溢出） |
| MobileCLIP（Apple） | Apple 自有样例代码许可，非 OSI 开源许可，权重再分发受限 | ❌ 商业分发存在 license 风险，放弃 |

另一决定性因素：EmbeddingGemma 2 是**图文同空间**的多模态 embedding，同一套索引同时支撑"相似照片分组"和"自然语言搜图"（v0.3），MobileCLIP 虽也是双塔但端侧 Core ML 端口成熟度与许可清晰度均不如前者。

### ADR-3：端侧全本地，不走云端

- 照片是最高敏级用户数据，全本地处理是最强隐私卖点（`NSPhotoLibraryUsageDescription` 明确写明"照片不会上传"）；
- 实测性能足够（见 §4），无需云端算力；
- 代价：模型 ~570MB 的分发问题。当前 Debug 构建脚本把 .mlpackage rsync 进 bundle；Release 需改为首次启动从 CDN 按需下载（`ModelManager` 已按"编译产物缓存在 Documents"的结构预留了切换点）。

### ADR-4：multifunction 模型 + 固定形状函数

用 `MLModelConfiguration.functionName`（iOS 18+）选 `vision_70` / `embed_128`，输入全为固定形状 fp16 张量——这是让计算图留在 Neural Engine 上的关键，也让单张耗时与图片内容无关（p95 ≈ mean），端侧耗时预估非常友好。deployment target 因此定为 iOS 18。

## 4. 性能实测数据

| 指标 | 数值 | 环境/说明 |
|---|---|---|
| 单张 embedding 全链路 | **~150 ms/张** | iPhone 13 Pro Max（A15），vision_70 + embed_128，ANE |
| 单张全链路（对照） | 54.3 ms（mean/p50/p95 几乎重合） | M3 Pro，ANE（`bench_embedding.py`，仅推理） |
| 端侧 OCR | ~50–100 ms/张 | A15，512px 图，fast 档 |
| 全库分组 | **~0.6 s / 4.6k 张** | 真机，分块 sgemm + sgemv 星型聚类 |
| 语义搜索 | 毫秒级 | 4,594 条 × 256 维暴力 sgemv |
| 存储 | **1 KB/张** | 256 维 × Float32 blob（SQLite） |
| 索引规模估算 | 1000 张 ≈ 2.5 min / 1 MB | 按 150ms/张、1KB/张推算 |

首次启动需 `MLModel.compileModel(at:)` 编译两个 .mlpackage（约 1 分钟），编译产物缓存到 `Documents/models-compiled/`，之后启动数秒。

## 5. 测试与自测体系

三层，覆盖"纯逻辑 → 真机链路 → 无人值守回归"：

### 5.1 单元测试（PhotoCleanerTests）

纯逻辑单测，不依赖 PhotoKit / 真模型，全部用构造数据：

- `DedupAnalyzerTests`：构造 256 维假向量验证星型聚类语义（链式不串组、真重复簇成组、双阈值互斥、单张不成组），存储用临时 SQLite 库；
- `FeaturePrintVerifierTests`：阈值读取逻辑（UserDefaults 默认值 0.15 / 用户设定值 / 非法值回退）；
- `EmbeddingStoreTests`：insert / fetchAll / existingIDs / count / delete 往返一致性。

运行：`xcodebuild test -scheme PhotoCleaner -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing PhotoCleanerTests`。

### 5.2 自测模式（-autoTest / -autoTestFull）

App 启动参数触发（`PhotoCleanerApp.runAutoTest`）：禁自动锁屏 → 自动授权检查 → 小范围扫 200 张（`-autoTestFull` 为全量）→ 3 个固定 query（猫/风景/文档）跑语义搜索 → 自动进分析页。跳过组质量打分与缩略图加载，保持无障碍树轻量。

### 5.3 日志回传（AutoTest）

所有关键链路日志（`[Engine]/[Scanner]/[ModelManager]/[Analyze]/[Search]/[AutoTest]`）同时写 stdout 和 `Documents/autotest.log`，带 ISO8601 时间戳。真机跑完后用 `devicectl` 拉回：

```bash
xcrun devicectl device copy from --device <udid> \
  --domain-type appDataContainer --domain-identifier com.ccl125.PhotoCleaner \
  --source Documents/autotest.log --destination ./autotest.log
```

注意：xcodebuild test 控制台只含测试进程输出，App 进程日志以 autotest.log 为准。

### 5.4 XCUITest（PhotoCleanerUITests）

`testFullFlow` 覆盖真机全流程：启动（`-autoTest`）→ 相册权限弹窗（interruption monitor + alerts 双通道兜底）→ 自动扫描 → 自动进分析页 → 等待分组结果 → 截图留档（XCTAttachment）。手机侧需一次性准备：自动锁定设为"永不"、USB 直连、测试前解锁停在主屏。

## 6. 已知边界

- 视频帧相似检测未做（管线支持，按 1fps 抽帧复用 vision 塔即可）；
- Release 分发的模型下载方案未实现；
- 大相册（>5 万张）分组耗时未实测，必要时可分块 + 早停。
