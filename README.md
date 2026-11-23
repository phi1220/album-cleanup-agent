# 相册清理 Agent / Photo Album Cleanup Agent

[简体中文](#简体中文) · [English](#english)

## 简体中文

本地优先的相册清理工具：模型给出选片建议，用户处理不确定项并决定最终删除。包含 macOS 原生应用和可独立使用的 Python CLI，两端的状态与偏好分别保存。

### macOS 应用

需要 macOS 15+、Xcode 或兼容的 Swift Command Line Tools；不依赖 Python，也不需要安装 Reef。

```bash
./build-mac-app.sh
open ".build/相册清理.app"
```

如果默认 SDK 与编译器不匹配，指定本机已安装的兼容 SDK。例如：

```bash
export MACOS_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
./build-mac-app.sh
./test-mac-review.sh
```

#### 语言设置

在“模型设置 → 界面语言”选择“跟随系统 / 简体中文 / English”，立即切换应用界面并保存选择。日期随界面语言格式化；后续模型生成的理由、偏好归纳和审核补充使用所选语言。已有的用户理由、模型历史解释和偏好内容保留原文。系统菜单和权限弹窗由 macOS 按系统或单独设置的 App 语言显示。

#### 使用流程

1. 授权访问系统“照片”，在“模型设置”中填写 HTTPS 兼容地址、视觉模型和 API Key，也可导入 `.env`。密钥保存在本机钥匙串。
2. 点击“分析全部”，处理本轮最多 100 张未分析照片。内部均衡分批，每批最多 12 张、最多两批并行，并尽量避开连拍和相邻拍摄时间切批。支持取消，已完成结果保存，失败项可重试。
3. 明确保留项自动退出待处理列表；明确清理且模型自报置信度至少 0.90 的进入“待删除图库”；其余待判断项弹窗审核。收藏照片和相似照片的对比保留项受保护。置信度不是经过统计校准的正确率。
4. 审核窗显示完整比例照片及理由。红色“删”加入待删除队列，绿色“留”保留，支持 ⌘D / ⌘K，理由选填；“稍后再看”不形成反馈。
5. 待删除图库支持多选“复活所选”或“全部删除”。复活只移出应用内队列；全部删除调用 PhotoKit，系统可能再次确认。取消或失败不新增删除反馈，也不自动重试。

刷新或分析结束后，保留未完成照片并补入新的未分析照片，最多 100 张；不确定项和待删除队列独立，不阻碍继续补图。可见缩略图、审核预览和分析按需从 iCloud 读取，显示下载进度，单张最多等待 120 秒，失败可重试。

系统删除会影响整个图库及启用 iCloud 照片的其他设备。删除后请在系统“照片”的“最近删除”中恢复；应用不清空“最近删除”。

#### 反馈记忆与策略更新

用户的删、留、复活及成功删除记录保存在本机；模型自己的建议不会成为用户偏好。同一照片使用最新选择，同向重复确认未填写新理由时保留先前理由，无理由选择只作为具体个例。

仅在“偏好记录”点击“更新记忆与自进化”时归纳和评估，分析照片直接使用已有记忆及新增反馈。归纳保留适用条件、例外和全部来源，原始反馈完整保存，每批成功后原子写入，可中断后接续；纠正使引用旧来源的归纳失效。

策略更新按照片及已知对比关系划分学习与留出验证，使用学习集记忆提出提示词候选，再用相同留出缩略图对比当前和候选策略。只有误清理不增加、清理召回不下降且人工改动减少才启用新版本。样本不足或验证失败时保留当前策略，支持回滚；模型或端点改变不沿用旧策略。

这是借鉴 Reef 流程的原生提示词进化，没有调用 Reef 框架或训练模型权重。一次留出回放不代表长期收益；尚无跨批次的全库相似照片比较。详细边界见 [UX-CONTRACT.md](UX-CONTRACT.md)。

#### 数据与隐私

- 审核记录：`~/Library/Application Support/AlbumCleanup/review-memory.json`；非秘密模型设置保存在 UserDefaults，API Key 保存在钥匙串。
- 点击分析或主动更新记忆与自进化时，向配置的服务发送最长边 768px 的重绘 JPEG、日期、尺寸、收藏状态及反馈/归纳文本。不发送原图文件、GPS/EXIF 或 PhotoKit ID 到提示词。
- PhotoKit 管理 iCloud 资源下载与缓存，应用不改变系统优化存储设置。
- 清空反馈移除原始反馈、归纳和进化策略，保留已有去留结果。

### Python CLI

需要 Python 3.11+；唯一依赖是 Pillow。CLI 扫描普通照片目录并导出经审核的清理清单，不移动或删除原图。

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python album_agent.py scan /absolute/path/to/photos
python album_agent.py groups --all
python album_agent.py agent
python album_agent.py export
```

Windows 可使用 `.venv\Scripts\python.exe` 运行对应命令。用 `python album_agent.py --help` 查看子命令。不同相册使用独立的状态目录：`python album_agent.py --state /path/to/state scan /path/to/photos`，顶层参数 `--state` 放在子命令之前。

#### 扫描与审核

支持 JPEG、PNG、WebP、BMP 和 TIFF。SHA-256 识别完全重复，拍摄时间和感知哈希识别连拍；缺少时间时以宽高比、感知哈希和低分辨率色彩匹配近似副本。分组和模糊度仅是本地参考，不冒充模型内容判断。

```bash
python album_agent.py show GROUP_ID
python album_agent.py review GROUP_ID --keep 1,3 --uncertain 2
python album_agent.py split GROUP_ID "1,2;3"
```

将 `GROUP_ID` 替换为 `groups` 输出的组号。`show` 生成缩略图拼图；`--keep all` 保护整组，`--keep none` 仅适用于单张或截图。重复/相似/连拍组至少保留一张。分错组应先 `split` 再审核。截图通过文件名识别，可用 `scan /path/to/photos --ocr tesseract` 提取文字，需另行安装 Tesseract。

默认离线 Agent 通过固定工具循环读取分组、证据和偏好后提交方案。按回车可跳过，确认后保存建议、工具轨迹、用户决定和策略版本。导出位于 `.album-agent/cleanup-plan.json`，包含相对路径、SHA-256 和组号，并验证候选文件内容未变；缩略图及审核状态均留在本机。

#### 连接视觉模型

```bash
cp .env.example .env
# 在本机填写密钥、供应商提供的兼容地址和视觉模型 ID。
python album_agent.py check-model
python album_agent.py agent "检查图片内容价值并提出选片建议" --group GROUP_ID --allow-remote
```

配置项为 `QWEN_API_KEY`、`QWEN_BASE_URL`、`QWEN_MODEL`，也兼容 `DASHSCOPE_API_KEY`，环境变量优先。`check-model` 仅发送文字；远程审核需指定组，最多 12 张，会发送该组缩略图和 OCR 文本。自建 JSON 网关可用 `ALBUM_MODEL_URL`、`ALBUM_MODEL_TOKEN` 接入。

模型可以建议清理单张照片和截图，须解释画面依据。未知个人用途不能直接视为低价值，不能凭缩略图断定原图模糊或凭证过期。所有 CLI 清理候选仍需用户审核。

#### 偏好与版本管理

- 排序偏好：`review GROUP_ID --keep 1 --scope kind --rank sharp`；范围可选 `kind` / `global`，排序可选 `sharp` / `bright` / `recent` / `resolution`。
- 内容偏好：模型提出类别、可观察条件和保留例外，用户审核后明确选择“以后同类”才保存。一次性选择、文件名、测试案例或模型意见都不会自动成为类别规则。`rules` 查看，`rollback-rules --yes` 回退。
- 连拍策略：至少两个连拍组的反馈使用 `--use-for-evolution` 明确授权参与提案；用 `review ... --split validation` / `--split test` 记录独立盲标。`evolve` 生成候选并验证安全性、召回和人工改动，`versions` 查看，`activate v1 --yes` 启用，`rollback --yes` 回退，`evaluate --split test` 评估。相同图片内容不得跨集合，事件级隔离由操作者负责。

也可直接记录显式类别偏好：

```bash
python album_agent.py review GROUP_ID --keep none --remember-category "类别" --remember-when "可观察条件" --remember-except "保留例外"
```

类别规则和连拍配置分别版本化保存，不等同于删除授权，也不与原生应用共享状态。

### 开发与验证

```bash
./test-mac-review.sh
.venv/bin/python -m unittest -v test_semantic_review.py
```

原生检查使用合成数据和注入回调，覆盖模型协议、删除保护、持久化、分批、iCloud 取消/超时、偏好来源及留出评估，不联网或修改真实图库。可选联网检查 `./test-mac-review.sh --check-learning .env` / `--check-vision .env` 只发送合成反馈或生成图片。实际图库交互仍需手动验证。

阶段日志：

```bash
/usr/bin/log stream --level info --predicate 'subsystem == "com.phi1220.albumcleanup.mac" AND category == "workflow"'
```

| 路径 | 用途 |
|---|---|
| `mac/AlbumCleanupMac.swift` | 原生窗口、图库状态与操作编排 |
| `mac/ModelReview.swift` | 模型配置、钥匙串、网络、预览与审核窗口 |
| `mac/ReviewProtocol.swift` | 模型协议、分批、删除保护与审核记忆 |
| `mac/PreferenceLearning.swift` | 偏好归纳、留出评估、策略版本与回滚 |
| `mac/Localization.swift` / `mac/Resources/` | 中英文本、格式化与语言设置 |
| `mac/tests/` | 原生离线与本地化检查 |
| `album_agent.py` / `album_core.py` | CLI、扫描分组、审核、导出与策略评估 |
| `agent_loop.py` / `qwen_api.py` | 固定工具循环与模型适配 |
| `semantic_preferences.py` | CLI 显式内容偏好 |
| `DESIGN.md` / `UX-CONTRACT.md` | 视觉约定与行为边界 |

仓库只保存源码、测试、文档与空白配置模板。本地用户偏好记录、`.env`、照片、状态目录、虚拟环境、缓存和 `.build/` 均不提交。

---

## English

A local-first photo cleanup tool: a model recommends selections, you review uncertain cases and decide when to delete. The project includes a native macOS app and an independent Python CLI. Each stores its own state and preferences.

### macOS app

Requires macOS 15+ and Xcode or compatible Swift Command Line Tools. Python and Reef are not required.

```bash
./build-mac-app.sh
open ".build/相册清理.app"
```

If the default SDK does not match your compiler, select a compatible SDK installed on your machine. For example:

```bash
export MACOS_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
./build-mac-app.sh
./test-mac-review.sh
```

#### Language settings

In Model Settings → Interface Language, choose Follow System, 简体中文 or English. The interface updates immediately and remembers your choice. Dates follow the interface locale; subsequent model reasons, preference summaries and policy guidance use the selected language. Existing user reasons, model explanations and preference content retain their original language. System menus and permission prompts follow macOS or its per-app language setting.

#### Workflow

The interface supports Simplified Chinese and English. Labels below include the corresponding Chinese names.

1. Grant access to Apple Photos. In “模型设置” (Model Settings), enter an HTTPS-compatible endpoint, a vision model ID and an API key, or import an existing `.env` file. The key is stored in the local Keychain.
2. Click “分析全部” (Analyze All) to process up to 100 unanalyzed photos in the current round. Balanced internal batches contain at most 12 photos, with up to two batches running concurrently. Batch boundaries try to keep bursts and closely timed shots together. You can cancel; completed results are saved and failed items can be retried.
3. Clear keep decisions leave the pending list automatically. Clear cleanup suggestions with model-reported confidence of at least 0.90 enter “待删除图库” (Pending Deletion); cases requiring your judgment open for review. Favorites and comparison keepers are protected. Confidence is not a statistically calibrated accuracy measure.
4. The review window shows uncropped photos and the model’s reasons. Red “删” queues a photo for deletion; green “留” keeps it. Use ⌘D / ⌘K and optionally provide a reason. “稍后再看” (Review Later) records no feedback.
5. In Pending Deletion, select photos and choose “复活所选” (Restore Selected), or use “全部删除” (Delete All). Restore only removes photos from the app’s queue. Delete All submits a PhotoKit deletion request, which may prompt for system confirmation. Cancellation or failure adds no deletion feedback and does not trigger an automatic retry.

After refresh or analysis, unfinished photos are retained and new unanalyzed photos fill the round up to 100. Uncertain cases and the deletion queue are separate and do not block new photos. Visible thumbnails, review previews and analysis load photos from iCloud as needed, showing download progress. Each image has a 120-second timeout and can be retried after failure.

System deletion affects the entire library and other devices using iCloud Photos. Recover deleted photos through Recently Deleted in Apple Photos; the app does not empty Recently Deleted.

#### Feedback memory and policy updates

Your keep, queue-for-deletion, restore and successful deletion actions are saved locally. Model suggestions do not become user preferences. The latest choice for a photo takes precedence. Reconfirming the same choice without a new reason preserves an earlier reason; choices without reasons remain individual examples.

Summarization and evaluation run only when you click “更新记忆与自进化” (Update Memory and Evolve) in “偏好记录” (Preference History). Photo analysis uses existing memory and new feedback directly. Summaries retain conditions, exceptions and all source references, while raw feedback remains complete. Each successful batch is saved atomically so interrupted work can resume. Corrections invalidate summaries that cite superseded sources.

Policy updates split photos and known comparison groups into training and held-out validation sets. Training memory produces a candidate prompt supplement; the current and candidate policies are then compared on the same held-out thumbnails. A new version is enabled only if unsafe cleanup does not increase, cleanup recall does not decrease and fewer manual edits are needed. Insufficient evidence or failed validation preserves the current policy. Rollback is supported, and changing the model or endpoint prevents reuse of old guidance.

This is native prompt evolution inspired by Reef’s workflow. It neither invokes the Reef framework nor trains model weights. One held-out replay does not establish long-term gains. Library-wide similarity comparison across batches is not implemented. See [UX-CONTRACT.md](UX-CONTRACT.md) for detailed boundaries.

#### Data and privacy

- Review records: `~/Library/Application Support/AlbumCleanup/review-memory.json`. Non-secret model settings use UserDefaults; API keys use Keychain.
- Analysis or an explicit memory/evolution update sends redrawn JPEG previews with a maximum dimension of 768px, dates, dimensions, favorite status and feedback/summary text to your configured service. Original image files, GPS/EXIF data and PhotoKit IDs are not included in prompts.
- PhotoKit manages iCloud downloads and caching. The app does not change the system’s optimized storage settings.
- Clearing feedback removes raw feedback, summaries and evolved policies while preserving existing keep/cleanup decisions.

### Python CLI

Requires Python 3.11+. Pillow is the only dependency. The CLI scans ordinary photo directories and exports reviewed cleanup plans; it does not move or delete original photos.

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python album_agent.py scan /absolute/path/to/photos
python album_agent.py groups --all
python album_agent.py agent
python album_agent.py export
```

On Windows, run the corresponding commands with `.venv\Scripts\python.exe`. Use `python album_agent.py --help` to list subcommands. Use a separate state directory for each album: `python album_agent.py --state /path/to/state scan /path/to/photos`. The top-level `--state` option must precede the subcommand.

#### Scanning and review

Supports JPEG, PNG, WebP, BMP and TIFF. SHA-256 identifies exact duplicates; capture times and perceptual hashes identify bursts. When timestamps are missing, aspect ratio, perceptual hash and low-resolution color samples help match near-identical copies. Grouping and blur estimates are local evidence, not model-based content judgments.

```bash
python album_agent.py show GROUP_ID
python album_agent.py review GROUP_ID --keep 1,3 --uncertain 2
python album_agent.py split GROUP_ID "1,2;3"
```

Replace `GROUP_ID` with an ID from `groups`. `show` creates thumbnail contact sheets. `--keep all` protects the entire group; `--keep none` is allowed only for single photos or screenshots. Duplicate, similar-photo and burst groups must retain at least one photo. Split incorrectly grouped photos before reviewing them. Screenshots are identified by filename. To extract text, install Tesseract separately and use `scan /path/to/photos --ocr tesseract`.

The default offline agent uses a fixed tool loop to read groups, evidence and preferences before proposing a review. Press Enter to skip. Confirmation saves the proposal, tool trace, user decision and policy version. Export writes `.album-agent/cleanup-plan.json` with relative paths, SHA-256 hashes and group IDs, checking that candidate files have not changed. Thumbnails and review state remain local.

#### Connecting a vision model

```bash
cp .env.example .env
# Fill in your key, provider's compatible endpoint and vision model ID locally.
python album_agent.py check-model
python album_agent.py agent "Assess image content value and recommend which photos to keep" --group GROUP_ID --allow-remote
```

Configure `QWEN_API_KEY`, `QWEN_BASE_URL` and `QWEN_MODEL`; `DASHSCOPE_API_KEY` is also supported. Environment variables take precedence. `check-model` sends text only. Remote review requires an explicit group of at most 12 photos and sends its thumbnails and OCR text. Custom JSON gateways can use `ALBUM_MODEL_URL` and `ALBUM_MODEL_TOKEN`.

The model may suggest cleanup for individual photos and screenshots, but must explain the visible evidence. Unknown personal usefulness does not imply low value, and thumbnails cannot establish original-image blur or document expiry. Every CLI cleanup candidate still requires user review.

#### Preferences and versioning

- Ranking preferences: `review GROUP_ID --keep 1 --scope kind --rank sharp`. Scope can be `kind` or `global`; ranking can be `sharp`, `bright`, `recent` or `resolution`.
- Content preferences: the model proposes a category, observable matching conditions and retention exceptions. These are saved only after review and an explicit choice to apply them to future matching photos. One-off choices, filenames, test cases and model opinions do not automatically become category rules. Inspect with `rules`; roll back with `rollback-rules --yes`.
- Burst policies: explicitly opt in feedback from at least two burst groups with `--use-for-evolution`. Record independent blind labels with `review ... --split validation` and `--split test`. `evolve` proposes and validates a candidate against safety, recall and manual edits. Use `versions` to inspect it, `activate v1 --yes` to enable it, `rollback --yes` to revert and `evaluate --split test` to evaluate. Identical image content cannot cross splits; the operator must ensure capture-event separation.

You can also record an explicit category preference directly:

```bash
python album_agent.py review GROUP_ID --keep none --remember-category "Category" --remember-when "Observable matching conditions" --remember-except "Retention exceptions"
```

Category rules and burst configurations are versioned separately. They do not authorize deletion and do not share state with the native app.

### Development and verification

```bash
./test-mac-review.sh
.venv/bin/python -m unittest -v test_semantic_review.py
```

Native checks use synthetic data and injected callbacks to cover model protocols, deletion protections, persistence, batching, iCloud cancellation/timeouts, preference provenance and held-out evaluation. They do not access the network or modify the real photo library. Optional live checks, `./test-mac-review.sh --check-learning .env` and `--check-vision .env`, send only synthetic feedback or a generated image. Real library interactions still require manual verification.

Workflow logs:

```bash
/usr/bin/log stream --level info --predicate 'subsystem == "com.phi1220.albumcleanup.mac" AND category == "workflow"'
```

| Path | Purpose |
|---|---|
| `mac/AlbumCleanupMac.swift` | Native window, library state and workflow orchestration |
| `mac/ModelReview.swift` | Model settings, Keychain, networking, previews and review windows |
| `mac/ReviewProtocol.swift` | Model protocol, batching, deletion protections and review memory |
| `mac/PreferenceLearning.swift` | Preference summaries, held-out evaluation, policy versions and rollback |
| `mac/Localization.swift` / `mac/Resources/` | Chinese/English text, formatting and language settings |
| `mac/tests/` | Native offline and localization checks |
| `album_agent.py` / `album_core.py` | CLI, scanning/grouping, review, export and policy evaluation |
| `agent_loop.py` / `qwen_api.py` | Fixed tool loop and model adapter |
| `semantic_preferences.py` | Explicit CLI content preferences |
| `DESIGN.md` / `UX-CONTRACT.md` | Visual conventions and behavioral boundaries |

The repository contains only source code, tests, documentation and an empty configuration template. Local user preference records, `.env`, photos, state directories, virtual environments, caches and `.build/` are not committed.
