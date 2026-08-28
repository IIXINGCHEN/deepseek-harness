# Agent Note: 改名前旧会话记录的 agent-preset 旧 id 别名

Status: implemented

[English](2026-08-28-agent-preset-legacy-id-alias.md) | 中文

## 问题

`3ca9c7d489` 将 PTC 预设的 id 从 `code` 改名为 `ptc`，并有意不动会话持久化词汇——改名提交注明会话持久化迁移是独立的后续变更。改名前创建的每个会话都在 `agentPreset` 投影里记录着 `agentPreset: "code"`，而 resume 路径解析的正是这个存储 id：`composeAgent` 读取投影后调用 `agentPresets.resolve("code")`，抛出 `UnknownPresetError`。用户可见的结果是：这类会话切换到 PTC 模式时总是失败，报 `preset "code" not found (available: standard, ptc, minimal, cordis, …)`，所有升级后的部署（包括本 fork 安装的 web profile）均受影响。

## 决策

`AgentPresets.resolve` 增加回退翻译表 `LEGACY_PRESET_IDS`，当前仅一行：`code → ptc`。查找顺序是先真实 id、后旧名翻译：若某个根目录仍提供名为 `code` 的预设，它继续获胜，因此该表永远不会遮蔽部署自定义的同名预设。当请求 id 与其翻译都无法解析时，抛出的 `UnknownPresetError` 报告请求 id 而非翻译后的 id，错误文案对调用方保持可读。

这一翻译是忠实的而非猜测：改名提交删除了 `presets/code/preset.yml` 并以相同组合、相同显示名（「PTC 模式」）创建了 `presets/ptc/`，因此以 `code` 记录的会话在改名后留下的同一组合下 resume。`resolveMountable` 与常驻挂载路径经由 `resolve` 继承该行为；恢复的会话仍记录自己的存储 id——模型可见状态保持已记录状态，不重写任何持久会话。

移除条件：待改名词汇的会话持久化迁移落地、且磁盘上不再有会话投影记录 `code` 后，删除 `code` 这一行。

## 未覆盖

记录了「已退役且无后继 id」的会话仍以原始错误失败；本表只映射有明确目标的改名。UI 预设选择器不变——它列出 `list()` 返回的当前 id，从不查表，因此预设创作与花名册表面与之前行为完全一致。

## 备选方案

**改为迁移存储的投影。** 把每条日志里的 `agentPreset: "code"` 重写为 `"ptc"` 可以消除别名需求，但这会修改持久的模型可见状态：fail-closed 的会话事件词汇策略使任何结构性重写都构成 `SESSION_FORMAT_VERSION` 变更，且改名提交本身就把它推迟到了会话持久化的后续 PR。它还只修复一个部署的会话，不是修复这一类问题。

**在用户根目录发布名为 `code` 的预设。** 在 harness 主目录的用户根放一个 `code` 目录即可让旧 id 解析，无需改代码。它落选是因为那是每台主机各自的配置：重复了已发布的组合、在组合下次变化时会与 `ptc` 漂移、且对其他升级部署毫无帮助。

**维持失败并附迁移提示。** 保留 resume 报错（上游目前的事实选择）并引导用户重建会话，保住了 id 的严格诚实。它落选是因为该会话本可恢复——它指名的组合仍以新 id 存在——硬失败消灭了别名用一行表项就能保住的价值。

## 后果

代价：现在有两个 id 拼写都会解析到 `ptc`，因此当某个根目录真的定义了名为 `code` 的自定义预设时，一个本想请求它的调用方可能拿到改名后的预设——今天不会发生（真实 `code` 根优先获胜），但编辑该表时必须保持「真实 id 优先」这一不变量。错误文案继续报告请求 id，未命中查询的报错读感与之前一致。

收益：改名前记录的每个会话都能在实际运行过的组合下恢复，现有会话的 PTC 模式切换随之恢复，且不触碰任何持久状态。本修复与 client-runtime seed、apiProxy adapter 同属 fork 本地兼容缝，`code` 行自带移除条件，该表不会比迁移本身活得更久。
