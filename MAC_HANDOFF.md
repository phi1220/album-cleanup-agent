# Mac 端 Codex 接手上下文

## 项目与当前目标

- 私有仓库：https://github.com/phi1220/album-cleanup-agent ，分支 `main`。
- 这是一个 **通用的、接入视觉模型的相册清理工具**：重复/连拍筛选、内容价值判断、可解释审核，以及从用户反馈中学习可复用偏好。
- 用户希望直接接入 Apple 系统“照片”图库。讨论后准备在 Mac 上继续开发；目前仓库仍是 Python CLI 原型，**没有 Swift、Xcode、PhotoKit 或 Mac App 工程**。
- 已讨论的建议路线是先做 Mac 原型，再考虑 iPhone。SwiftUI + PhotoKit 是建议方案，尚未落实；不要把建议当成已完成实现。

## 用户明确强调的产品原则

1. **一定要接真实模型**。离线规则可以提取特征、辅助筛选，但不能把纯规则运行描述为模型分析。
2. 模型的语义判断必须能影响去留，不能只检测重复；单张照片也可能是清理候选。
3. 需要解释“为什么删”和“为什么从相似照片中保留这一张”。清晰度分数只是参考，不能代替构图、姿态、内容与个人价值的比较。
4. 要开发通用工具。频谱图、二维码只是测试中遇到的案例，**用户没有批准把这两类设成默认删除规则**。
5. 用户最终选择固化通用反馈 SOP。不要再次拿那四张示例要求用户确认，只为演示规则学习。
6. 用户希望助手直接推进已授权工作，避免反复确认同一事项。产品中“是否记住长期偏好”的选择仍是必要的实际功能。

## 已确定并实现的通用反馈 SOP

1. 模型查看当前审核组，区分图片质量、语义价值和不确定之处，先检查已确认偏好。
2. 内容价值不明确时，展示实际图片与具体理由，让用户选保留、清理或待定。
3. 有可复用的可见特征时，提出范围明确的类别规则；用户选片后再选择“仅本次”或“以后同类也这样处理”。
4. 只有明确选择未来适用范围，才保存 **类别、匹配条件、保留例外、处理方式、示例引用**，注入后续模型提示词。
5. 后续命中条件且不符合例外时按偏好建议处理；匹配不明确则交给用户。支持纠正和回滚。

规则不能由文件名、测试案例、模型自己的判断、用户沉默或一次性删除自动泛化而来。待定、混合标签和验证/测试标签不用于学习。当前实现选择 **动态 prompt + 版本化 JSON**，没有创建独立 skill。

## 现有代码地图

- `album_agent.py`：CLI、扫描/展示/审核/导出编排，连拍策略评估与版本管理。
- `album_core.py`：Pillow 特征、分组、缩略图/拼图、本地推荐、HTTP 模型网关和直接模型建议。
- `agent_loop.py`：固定工具注册表和受控 Agent 循环；`LocalPlanner` 离线，`JsonPlanner` 调模型。最多 8 步；远程任务需明确指定组，最多 12 张图片。模型只能给审核建议。
- `qwen_api.py`：OpenAI 兼容 Chat Completions 适配，把图片证据转为图片输入并解析 JSON 动作。
- `semantic_preferences.py`：`FEEDBACK_SOP`、规则验证、用户确认、偏好版本、动态 prompt、回滚。
- `test_semantic_review.py`：目前 11 项自动化测试，覆盖语义候选、ID 边界、反馈确认/跳过、后续 prompt 注入、修正与回滚、评估集隔离等。

主要链路：照片目录 → 扫描/分组 → 本地证据 + 可选模型 → 展示理由和拼图 → 用户审核 → 导出清理计划。

## 持久化与边界

- 默认状态目录 `.album-agent/`，一个状态目录绑定一个相册根目录；可用顶层参数 `--state PATH` 切换。
- `scan.json`：扫描分组；`reviews.json`：审核与反馈；`thumbs/`、`review/`：本地图片缓存。
- `versions.json`：连拍排序/保留数量等策略版本，需独立验证集通过指标门槛后人工启用。
- `semantic-rules.json`：用户明确确认的语义偏好，版本 `s0`、`s1`…，含父版本和示例哈希。
- Agent 的 `propose_review` 可附 `semantic_rule`。审核后固定代码询问是否记住；模型不能自行确认。直接模型建议路径也会读取当前偏好。
- 同类别的新明确决定会替换旧偏好；`rules` 查看，`rollback-rules --yes` 回退。
- 当前规则影响的是清理建议，**不等同于永久删除授权**。标准 CLI 的 `export` 只生成经审核清单，校验路径和 SHA-256，尚无实际移动/删除执行器。
- 重复/相似/连拍组至少保留一张；单张图片和截图允许全部成为清理候选。

## Reef 的实际关系

借鉴 Reef 的“反馈 → 策略候选 → 评估 → 版本化/回滚”思想，**未安装或接入 Reef 框架**。

目前连拍进化只搜索受控配置（保留数量、排序信号），评估运行本地 `recommend()`，不是完整远程 Agent 的端到端评估。语义偏好是用户显式授权的学习，与统计验证的连拍进化分开管理。不要声称已有经过实证的持续自我提升能力。

## Windows 上已做的真实模型实验

- 本地 `testphotos` 有 32 张图片，扫描得到 29 组：两组完全重复、一组近似，其余为单张。
- 使用真实视觉模型、256px 缩略图，先分批分析，再做全册复核。首版试清理副本保留 24 张，排除 8 张候选（2 张完全重复，6 张近似冗余）。
- 后来开放语义清理并重审，新增 1 张孤立方形码候选：第二版试清理副本保留 23 张；20 张建议保留、9 张候选、3 张待定。
- 全部 32 张原图未删除或移动，已验证哈希。以上均是试清理副本，**不等于用户逐张批准的正式审核数据**。
- 模型存在过度保守、用“同场景”代替真正选片比较、从缩略图推断原图不可读等问题。原图检查后修正过方形码候选的置信度与理由；本地解码失败也不能证明码无效。
- 两条类别规则曾由模型生成草案，但用户纠正需求为通用工具。草案已标记为测试示例，没有启用任何频谱图/二维码个人偏好。

## Mac 获取与启动

需要 Python 3.11+；当前唯一 Python 依赖是 Pillow。仓库代码已上传，Windows 上 11 项测试通过；Mac 上尚未验证。

```bash
git clone https://github.com/phi1220/album-cleanup-agent.git
cd album-cleanup-agent
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python -m unittest test_semantic_review.py
cp .env.example .env
# 在本机编辑 .env，填入模型配置；不要提交密钥。
python album_agent.py check-model
python album_agent.py scan /absolute/path/to/test-photos
python album_agent.py groups --all
# 从上一条输出中选择实际组号，替换 GROUP_ID：
python album_agent.py agent "检查图片内容价值并提出审核建议" --group GROUP_ID --allow-remote
```

原 Windows 环境实际使用的非秘密配置为：

```dotenv
QWEN_BASE_URL=https://cn-beijing.maas.qianwenaiapi.com/compatible-mode/v1
QWEN_MODEL=qwen3.8-flash
```

这与 `.env.example` 的供应商默认示例不同。API Key 由用户在 Mac 本机另行配置，不在本文或仓库中。HTTP 等待时间已从 20 秒改为 120 秒，真实多图请求曾较慢。

GitHub 中仅有源码、测试、文档和空白配置模板。`.env`、`testphotos/`、`.album-agent/`（包括试清理结果和本地试验脚本）、缓存和虚拟环境均未上传。Mac 需要另备测试照片，不要假设 Windows 路径或本地实验文件存在。

## Mac 下一步建议

1. 检查 Mac 的 Xcode、Swift、系统版本及图库授权条件，先验证当前 Python 测试和真实模型接口。
2. 用 PhotoKit 做最小图库接入：授权、读取资产与缩略图、候选展示。图库资产不能简单等同于普通文件路径，需设计资产标识和分析记录的映射。
3. 将“候选图片 + 对比保留项 + 理由 + 本次去留 + 是否记住同类偏好”做成可用审核流程，复用上述 SOP。
4. 再接 PhotoKit 修改请求，明确区分从相簿移除与从整个图库删除；处理权限范围变化、iCloud 下载和操作失败。实际系统图库修改能力目前尚未实现。
5. 优先小而可运行的 Mac 版本；Swift 与现有 Python 如何复用可按实际环境决定，无需立即重写全部逻辑。

参考 Apple 官方文档：[PhotoKit](https://developer.apple.com/documentation/photos)、[照片图库权限](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app)、[图库修改](https://developer.apple.com/documentation/photokit/requesting-changes-to-the-photo-library)。

