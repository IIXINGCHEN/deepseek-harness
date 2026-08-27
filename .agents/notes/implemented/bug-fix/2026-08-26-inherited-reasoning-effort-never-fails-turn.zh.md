# Agent Note: 继承而来的推理强度不会导致轮次失败

Status: implemented

[English](2026-08-26-inherited-reasoning-effort-never-fails-turn.md) | 中文

## Problem

某会话每一轮都以 `UNSUPPORTED_REASONING_EFFORT: provider "vision-toolkit-oxa" model "stealth/ox-alpha" does not support reasoning effort "off"` 失败，而此前在路由切换时剥离过期推理强度的修复轮（20260826-174500）没有止住它。对照部署环境核实：`settings.yaml` 保存着 `agent-default-model: {provider: vision-toolkit-oxa, model: stealth/ox-alpha, reasoningEffort: off}`，且该模型是 llm-pi-ai 手工声明路由下未声明 `reasoningEfforts` 的条目，适配器因此完全不报告推理能力——对这类模型，`LlmRuntime.resolveCallWithInfo` 会拒绝任何被请求的推理强度，包括 `off`。这份保存的三元组被原样送进每个新会话：Web 网关在会话日志尚无 header 时用默认模型选择播种每会话 selection（`selectionFor().current`），headless bundle 以同样方式播种 `installModelSelection`，于是过期强度被当作用户选择应用，第一次 `prepareCall` 就令轮次失败。

能把继承强度送到不兼容模型面前的路径有三条：过期的已保存默认选择（保存之后目录或 profile 变化，或手工编辑过 settings 文档）、同路由能力变化令已记录的显式强度失效、以及任何为别的模型选了值又原样转发的 `agent/request` waterfall 监听器。当 provider 与 model 都未变化时，路由切换守卫对这三条都不触发。实时选择是另一个层级：`session.selectModel` 在接受切换前会解析确切路由，实时挑中不支持的强度会在 RPC 层以 `model-unavailable` 拒绝——该契约正确且保持不变。

## Decision

`ReactLoopAgent.buildRequest` 负责区分继承值与实时值。当 `prepareCall` 以 `UNSUPPORTED_REASONING_EFFORT` 拒绝提议且配置带有推理强度时，循环丢弃该强度，记录一条包含路由与被丢弃值的警告，再准备一次；模型自身默认值随之生效，轮次继续。由于每个实时选择在被选出时已经过校验，能到达这道守卫的强度只会是继承值——持久 header 中的值、已保存的默认选择、或插件提议——因此降级到模型默认永远不会覆盖实时用户选择。被投毒来源在后续步骤重新注入的强度会被再次丢弃；每次丢弃都告警，让该状况在重新选择之前始终可在日志中观察。第二次准备不设恢复逻辑：丢弃后配置不再携带强度，若再次被拒，说明适配器自己的默认值与其声明的强度集合不一致，属于 `resolveCallWithInfo` 已负责的适配器元数据问题。

两个配套接缝完成隔离。Web 网关的 `selectionFor().current` 不再把适配器物化的默认值当作显式选择从已记录 header 中复制出来：当 `adapterDefaults.reasoningEffort` 标记该值由适配器提供时，selection 不报告强度，与 `requestProposal` 对循环自身种子所做的处理一致——否则下一次同路由选择会把模型默认值钉成用户选择。20260826-174500 轮的种子守卫保留：循环实例只在已记录 header 命名其声明路由时恢复显式强度，`agent/request` waterfall 中的路由变化会丢弃未经改动继承下来的强度。三层合起来意味着：强度进入请求只有三种形态——仍然受支持的显式选择、waterfall 覆写、或模型自身默认值。

## Alternatives considered

**在 `resolveCallWithInfo` 内钳制或别名映射强度。** 拒绝：该方法的文档契约是对调用方提供的值做校验、不钳制、不别名，且 `resolveCallConfig` 的消费方（实时选择、独立查询）依赖这个拒绝行为。知道"值是继承来的"的是循环，不是解析器。

**在 `installModelSelection` 内归一化。** 拒绝：模型选择接缝需要在每次请求时查询精确模型能力，把它耦合到自己并不拥有的 LLM 运行时，而且未安装 selection 的 agent（subagent 组合、直接使用 `AgentLoop` 的消费方）仍会失败。

**保持失败并向用户要求修复 `settings.yaml`。** 拒绝作为运行时行为：过期的持久三元组会让每个新会话在手工修复文档前完全不可用，而 composer 的强度面板本就为所选模型展示正确档位。警告日志让状况对操作者可见。

## Consequences

精确模型不支持的继承强度降级为模型默认值并按请求告警一次，轮次不再失败；`request/header` 随后记录物化默认值及其 `adapterDefaults` 标记，下一步提议再次剥离它，日志保持可重建。`session.selectModel` 仍拒绝实时挑中的不支持强度，`resolveCallConfig` 保持"先校验后 I/O"的拒绝契约。被过期默认选择投毒的会话在用户重新选择模型之前每步都会告警，重新选择会经由已校验路径更新保存的三元组。`agent-default-model` 服务不变：其文档仍是过去某次已校验选择的快照，消费方不再把它当作实时校验过的输入。
