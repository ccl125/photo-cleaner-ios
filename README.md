# PhotoCleaner（iOS 真机验证 App）

用 EmbeddingGemma 2 的 Core ML 端口在 iPhone 上做相册相似照片检测的最小可用 App。
原型验证数据见 `../photo-cleaner-prototype/RESULTS.md`（vision_70 + MRL 256 维 + 阈值 0.93）。

## 环境

- macOS 27 + Xcode 27.1（iOS 27.1 SDK）
- 目标设备：iPhone 13 Pro Max（A15，iOS 27），deployment target iOS 18（multifunction 模型要求）
- 工程由 XcodeGen 生成（`brew install xcodegen`），不要手改 .xcodeproj

## 打开与运行

```bash
cd photo-cleaner-ios
xcodegen generate          # 生成/刷新 PhotoCleaner.xcodeproj
open PhotoCleaner.xcodeproj
```

1. **选签名 Team**：工程配置里 `DEVELOPMENT_TEAM` 是占位空值。Xcode 打开工程 → target PhotoCleaner → Signing & Capabilities → 选你自己的 Personal Team（Automatic 签名，Bundle ID `com.ccl125.PhotoCleaner` 如冲突可改成自己的前缀）。
2. **连真机**：iPhone 数据线连接，信任电脑；Xcode 顶部选你的 iPhone → Run。首次安装会把 ~570MB 模型一起拷进去（Debug 构建脚本自动从 `../photo-cleaner-prototype/models/embeddinggemma-2-coreml/` rsync 两个 .mlpackage 进 bundle，安装一次到位，之后增量很快）。
3. **首次启动**：App 会用 `MLModel.compileModel(at:)` 把 .mlpackage 编译成 .mlmodelc 并缓存到 Documents/models-compiled/，编译 + ANE 首次加载约需 1 分钟左右，界面会停在"正在加载模型"。之后启动只需数秒。

## 使用流程

首页授权照片访问（支持 Limited 模式）→ 开始扫描（最近 6 个月图片，可暂停/继续，重启 App 自动断点续跑）→ 索引完成后进入"分析相似照片" → 分组结果页（默认每组保留第一张，点击缩略图可改选）→ 底部"删除选中"按钮 → 系统弹窗二次确认 → 照片进"最近删除"。

## 技术要点

- **推理管线**（`EmbeddingEngine.swift`）与 Python 原型逐行对齐：保边缩放（边长 48px 倍数、≤630 patch）→ RGB/255 → vision_70 → 70 个 image token → 拼 `<bos> <|image|> [tokens] <image|> <eos>` → embed_128 → 768 维 → 截 256 维 → L2 归一化。
- **multifunction 模型**通过 `MLModelConfiguration.functionName`（iOS 18+ API）选择 `vision_70` / `embed_128`，`computeUnits = .all`。
- **特殊 token 与位置表**由 Python 一次性导出为 fp16 二进制随包带走（`Resources/special_tokens.f16` 4×512，`Resources/position_embeddings.f16` 2×1024×768），Swift 侧直接按 Float16 读，无需 bf16 转换。重新生成：`cd ../photo-cleaner-prototype && .venv/bin/python export_ios_assets.py`。
- **存储**（`EmbeddingStore.swift`）：SQLite3 C API 零依赖，`localIdentifier → 256 维 Float32 blob`，按 id 跳过实现断点续跑。
- **分组**（`DedupAnalyzer.swift`）：分块 `cblas_sgemm`（256 行查询块 × 全库矩阵，多核并行）算 cosine，内存 O(256×n)，逐块进度回调；阈值 0.93，union-find 连通分组。
- **删除**：`PHPhotoLibrary.performChanges` + `PHAssetChangeRequest.deleteAssets`，系统确认框为预期行为。

## 自动化真机回归（XCUITest）

工程含 UI 测试 target `PhotoCleanerUITests`（project.yml 声明，regen 后生效），测试用例 `testFullFlow` 覆盖：启动（`-autoTest` 自测模式）→ 相册权限弹窗（interruption monitor + alerts 双通道兜底）→ 自动小范围扫描 200 张 → 自动进分析页 → 等待分组结果（重复/相似 section 或空态）→ 截图留档（XCTAttachment）→ 组数与 [AutoTest] 状态写测试日志。

**手机一次性准备**（必须，否则安装/preflight 阶段锁屏会断 CoreDevice 链路）：
1. 设置 → 显示与亮度 → 自动锁定 → **永不**
2. 保持 USB 直连（别经 hub），测试前解锁一次停在主屏

**一条命令回归**：

```bash
cd photo-cleaner-ios && xcodegen generate && \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -scheme PhotoCleaner -destination 'id=00008110-000829000A51801E' -allowProvisioningUpdates 2>&1 | tee uitest.log
```

自测模式行为（App 侧，`-autoTest` launch arg）：
- 禁自动锁屏（`isIdleTimerDisabled`）、自动授权检查 → 扫 200 张 → 自动跳分析页
- 跳过组质量打分与缩略图加载（缩短回归时长、保持无障碍树轻量）；打分链路由相似组"为这组打分推荐"按钮覆盖
- 所有日志（[Engine]/[Scanner]/[ModelManager]/[Analyze]/[AutoTest]）同时写 stdout 和 `Documents/autotest.log`，可从设备拉回：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun devicectl device copy from --device 00008110-000829000A51801E \
  --domain-type appDataContainer --domain-identifier com.ccl125.PhotoCleaner \
  --source Documents/autotest.log --destination ./autotest.log
```

已知限制：xcodebuild test 的控制台日志只含测试进程（[UITest] 前缀）输出；App 进程 stdout 不进测试日志，链路数据以 autotest.log 为准。

## 模型分发说明（重要）

模型 ~570MB **不进 Release bundle**（拷贝脚本只在 Debug 生效）。正式发布前需要换成下载方案：首次启动从 CDN 拉取两个 .mlpackage 存到 Documents，或按 FluidInference 的 FluidUse 方式做按需下载。当前 `ModelManager` 已按"编译产物缓存在 Documents"的结构设计，届时只需把"从 bundle 找源包"替换为"从 Documents 找已下载包"。

## 待办 / 已知边界

- [ ] 真机跑通后把单张耗时、吞吐数据回填到原型 RESULTS.md（A15 vs M3 Pro 对比）
- [ ] 视频帧相似检测未做（管线支持，按 1fps 抽帧复用 vision 塔即可）
- [ ] 大相册（>5 万张）下 union-find 前的 sgemv 逐行计算耗时未实测，必要时可分块+早停
- [ ] Release 分发的模型下载方案未实现

## v0.2 功能说明

- **质量打分 + 组内推荐保留**（`QualityScorer.swift`）：只对组内成员算分。模糊用 Laplacian 方差（256px 灰度 + vImage PlanarF 卷积，log 后组内 min-max 归一）；人脸用 `VNDetectFaceCaptureQualityRequest` 取最高值（无人脸记中性 0.5）；分辨率按组内最大像素数归一。综合分 = 0.4 模糊 + 0.3 人脸 + 0.3 分辨率。ResultsView 给推荐项打"推荐"徽标。
- **清理清单**（`CleanupScanner.swift` + `CleanupListView.swift`）：截图（mediaSubtypes & photoScreenshot）、录屏（video + videoScreenRecording）、大视频 Top 50（PHAssetResource fileSize 降序）。网格勾选 + 全选，删除走统一的 `PhotoDeleter.delete`（与分组删除同一入口，系统确认框为预期行为）。首页统计区显示"截图 X 张 / 录屏 Y 个 / 大视频 Z GB"。
- **双阈值分档**（`DedupAnalyzer.swift`）：同一次 sgemv 逐行扫描里判断两档，边集互斥（同一对只归最高命中档）——重复组 >0.93（默认保留推荐项、其余勾选删除），相似组 0.80–0.93（默认全保留、仅显示推荐徽标，橙色弱强调）。ResultsView 分两个 Section 展示。
