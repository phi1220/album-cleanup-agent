# Photo Album Cleanup Agent

本地优先的相册清理 Agent。用 `agent` 启动一次任务，Agent 自行调用工具取证，提交选片方案给用户审核。已审核的清理项可导出为 JSON。

## 安装和使用

需要 Python 3.11 或更新版本。在项目目录运行：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe album_agent.py scan E:\photos
.\.venv\Scripts\python.exe album_agent.py agent
.\.venv\Scripts\python.exe album_agent.py export
```

替换 `GROUP_ID` 为 `groups` 输出中的组号。可以打开 `show` 输出的本地缩略图拼图，根据编号选择保留项。比如 `review GROUP_ID --keep 1,3 --uncertain 2` 保留 1 和 3，将 2 标为待定。其余照片视为本次明确同意清理的候选。`--keep all` 可以保护整组。分错组时先运行 `split GROUP_ID "1,2;3"`，再审核新组。`groups --all` 也列出单张照片。

`agent --group GROUP_ID` 可以指定一组。Agent 调用 `list_groups` 查找待审组，调用 `inspect_group` 读取证据，可以用 `read_preferences` 读取个人偏好，用 `ask_user` 提一个澄清问题，最后用 `propose_review` 提交建议。CLI 展示工具轨迹、明确建议和预览路径，等待用户做最终选择。直接按回车可以跳过。确认后的记录保存建议、工具轨迹、用户决定和策略版本。默认的离线规划器按明确规则跑通同一个工具循环，语言任务由接入后的模型规划器理解。

导出文件为 `.album-agent/cleanup-plan.json`，包含相对路径、SHA-256 和组号。导出时验证清理候选文件内容，原照片留在原位置。不同用户或相册请用独立的 `--state PATH`（放在子命令前）。状态目录包含缩略图、文字和审核数据，请保存在本机。

扫描用 SHA-256 找完全重复，用拍摄时间和感知哈希找相似连拍，用边缘方差给出模糊度参考。缺少拍摄时间时，还会结合感知哈希、宽高比和低分辨率色彩来匹配高度相似的整张照片，例如同一张 JPEG 的重压缩版本。这类候选显示为 `similar`，由用户确认。首版通过文件名识别截图，安装 Tesseract 后使用 `scan E:\photos --ocr tesseract`（或提供 exe 路径）提取文字。OCR 失败的照片会保留在扫描结果中，查看记录里的 `ocr_warning`。首版支持 JPEG、PNG、WebP、BMP 和 TIFF。

## 偏好与 Harness 进化

- `review GROUP_ID --keep 1 --scope kind --rank sharp` 保存针对该类照片的显式排序偏好。也可用 `global`，以及 `bright`（接近中间亮度）、`recent`、`resolution`。默认审核只作用于当前组。重新审核该组可以修改记录。
- 在至少两个连拍组里，用 `agent --group GROUP_ID --use-for-evolution` 允许这条审核参与候选策略的生成。也可以用 `review` 手动录入反馈。
- 挑选不同拍摄事件的照片组做验证和测试。用 `review GROUP_ID --split validation` 和 `review GROUP_ID --split test` 做盲标。请勿事先查看这些组的建议；程序会检查相同图片内容跨集合，事件级隔离由操作者负责。
- 运行 `evolve`。提案器根据反馈中的选片数量和排序误差生成一份连拍策略候选，在独立验证组上与当前版本比较。误清理建议率和必留照片触犯率不得上升，可清理召回不得下降，人工修改数须下降。程序至少要求两个验证组且能计算这些指标。
- 用 `versions` 查看结果，`activate v1 --yes` 确认启用，或 `rollback --yes` 回退。保持测试集独立，在启用后用 `evaluate --split test` 比较固定策略、只学习偏好、偏好加 Harness 更新，报告可清理召回、误清理和改动次数。这些是离线编辑量估计，真实审核时间需要用户实验。

### 从审核学习语义偏好

工具采用通用的语义反馈 SOP，不预设某类图片必须删除：

1. 模型检查当前审核组，分别判断图片质量、内容价值及不确定之处；已确认偏好优先参与判断。
2. 遇到用途或保留价值不明确的内容，展示实际图片与理由，交由用户选择保留、清理或待定。有可复用的可见特征时，提出类别规则草案。
3. 用户选择去留后，展示规则的适用条件和保留例外，再选择“仅本次”或“以后同类”。回车仅本次，输入 `yes` 才记住。
4. 从明确的同类反馈保存“类别、可观察条件、例外、用户决定、示例引用”，并注入后续模型提示词。文件名、测试图片或模型猜测都不能自行成为用户偏好。
5. 命中已有规则的图片按偏好建议处理；匹配不明确时再次交给用户。用户可纠正类别偏好或回滚。待定、混合标签及验证/测试标签不用于学习。

这一流程适用于任意语义类别。频谱图、二维码等仅可作为测试案例，未经用户明确选择未来适用范围，不写入通用清理规则。远程 `agent --group GROUP_ID --allow-remote` 可以提出规则草案，后续确认由固定审核代码处理。

也可在明确审核时直接记住规则，例如：

```powershell
python album_agent.py review GROUP_ID --keep none --remember-category "类别名称" --remember-when "可观察的匹配条件" --remember-except "需要保留或再次询问的例外"
python album_agent.py rules
python album_agent.py rollback-rules --yes
```

类别规则保存在当前相册状态目录的 `semantic-rules.json`，记录示例图片哈希、用户决定及父版本。每次模型请求都将当前规则写入提示词；以后命中条件且不符合例外的照片会按已确认偏好建议清理或保留，不再重复询问相同偏好。相同类别的新决定覆盖旧规则，可回退。这是用户明确授权的偏好学习，与需要独立验证集证明收益的连拍参数进化分别管理；模型建议本身不会成为已审核的文件清理授权。

版本化策略和验证流程参考 Reef。当前实现用本地提案器修改受控的连拍策略配置。用户审核、版本闸门和文件导出由固定代码负责。

## 模型接入

在项目目录打开 `.env`，填入 `QWEN_API_KEY`、`QWEN_BASE_URL` 和 `QWEN_MODEL`。现有配置也可继续用 `DASHSCOPE_API_KEY` 存放密钥。用供应商提供的 OpenAI 兼容地址和支持图片输入的模型 ID。配置示例默认用百炼北京接入地址和 `qwen3-vl-flash`。[百炼接入地址](https://help.aliyun.com/zh/model-studio/base-url) · [模型说明](https://help.aliyun.com/zh/model-studio/qwen3-vl-flash)

```powershell
python album_agent.py check-model
python album_agent.py agent "帮我筛选这组连拍" --group GROUP_ID --allow-remote
```

`check-model` 发一条纯文本请求，检查 API 和 JSON 返回。第二条命令会将指定组的缩略图和 OCR 文本发给配置的模型。用虚拟环境时，将 `python` 替换为 `.\.venv\Scripts\python.exe`。真实密钥放在本机的 `.env` 或环境变量里。

Agent 通过 `Planner.next_action(request)` 请求下一步。百炼适配器在 `qwen_api.py`，将缩略图转换成图片输入，并解析返回的动作 JSON。程序校验工具和照片 ID，远程组上限为 12 张。`evolve --allow-remote` 也使用同一配置，请求仅包含候选策略和汇总分数。自建 JSON 网关仍可通过环境变量 `ALBUM_MODEL_URL` 和 `ALBUM_MODEL_TOKEN` 接入。

远程模型也会判断内容价值：误拍、无有效主体、缺少可用信息的临时记录可以成为清理候选，单张照片和截图都可提出不保留建议。建议须说明画面证据；未知个人用途不等于低价值，也不能仅凭缩略图断定原图模糊或凭证过期。用户仍需审核，重复和相似组至少保留一张。离线规则不会进行这类语义判断。

