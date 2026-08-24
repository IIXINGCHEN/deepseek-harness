# Code Review: 本轮运行失败 Cannot read properties of undefined (reading 'prepare')

- 日期: 2026-08-20
- Scope: 事故驱动的定向路径审查（tool scheduler 查找与调度路径），非 diff 审查
- Profile: standard / focus: correctness + reliability
- 事故会话: `~/.dsh/sessions/--E-API-ZGiYW3-home-4.1.7--/session-11827fdd-5f02-4dd2-ba4c-e1bce22d0532`
- 本仓库检出: master @ 141eb6fef8 (0.1.0-rc.8)；全局安装: `@deepseek-ai/dsh@0.1.0-rc.7`

## Stats

- Files Modified: 0
- Files Added: 1（本报告）
- Files Deleted: 0
- New lines: 0（无代码变更）
- Deleted lines: 0

## 事故证据链（全部来自实际产物，非推断）

1. UI 前缀「本轮运行失败」= `packages/client/ui-conversation/src/client/locales.ts:131`（`message.turnError`），后接 `turn/end` 事件的 `error.message`。
2. 会话日志 turn 4（13:27:57）事件序列：
   - seq 84 `tool/call`：模型调用 `grep`，`{"pattern":"music|player|song|playlist|audio"}`（`grep` 为合法注册名，见 `packages/fs/tool-fs-search/src/grep.ts:283`）
   - seq 85 `step/end`（+2ms）
   - seq 86 `turn/end`：`{"kind":"error","error":{"message":"Cannot read properties of undefined (reading 'prepare')","code":"UNKNOWN"}}`
   - 无任何 `tool/result` 事件 → 崩溃点在 `appendToolCall` 之后、工具体执行之前，即 `packages/core/agent-loop/src/tool-calls.ts:169`。
3. 同一会话 turn 1–3（12:45/12:59/13:23，无 `tool/call` 事件）报守卫消息：`tool scheduler is not available on ctx.tools: ensure ToolRuntime service is properly registered`。该消息不在本仓库源码、不在本仓库构建产物、不在全局 rc.7 安装中；仅存在于本仓库 `.git` pack 对象（上游更新版代码）。→ turn 1–3 与 turn 4 由**不同代码版本**的服务进程处理，两次执行之间（13:26:56–13:27:57）发生进程重启/换源。
4. 机器上同时存在三个 dsh 代码版本：全局 `@deepseek-ai/dsh@0.1.0-rc.7`（`lib/index.js:193` 无守卫）、本仓库 rc.8（`src/tool-calls.ts:169` 与 `lib/index.js:193` 均无守卫）、上游更新版（含守卫，pack 中）。桌面启动器 `~/.dsh/desktop-launcher/launcher.ps1` 启动全局 `dsh web`；`start-dsh.ps1` 启动仓库构建并先杀 3080 端口旧实例——两条启动路径共享端口与 `~/.dsh` 会话目录。
5. `~/.dsh/cordis.patch.yml` 内容为 `[]`——第三方插件 `dsh-memory-evolve` 的 bundle 补丁层当前为空，排除补丁注入模块的可能。

## Top issues

```
severity: blocker
file: packages/core/agent-loop/src/tool-calls.ts
symbol: runGroup / startCall / commitReady
issue: 调度器查找无守卫，符号缺失时把原始 TypeError 直接当作 turn 错误
detail: 第 169 行 `const prepared = await ctx.tools[TOOL_RUNTIME_SCHEDULER].prepare(call.exec)`
  及第 152–153 行 `.finalize/.finish` 均对 `ctx.tools[TOOL_RUNTIME_SCHEDULER]` 直接解引用。
  当 ToolRuntime 未注册或符号标识不一致时，抛出 "Cannot read properties of undefined
  (reading 'prepare')"，成为用户可见的 turn 错误（本次事故的直接表现）。违反仓库自身
  约定 "Misconfiguration fails loud at load … never silently skip"（AGENTS.md L114）。
  上游更新版已加守卫（turn 1–3 的报错消息即守卫产物），本地 rc.8 检出缺失。
suggestion: 在 runGroup 顶部解析一次调度器并复用；缺失时抛带指引的描述性错误
  （对齐上游消息 'tool scheduler is not available on ctx.tools: ensure ToolRuntime
  service is properly registered'）。见下方 Suggested patch。
```

```
severity: major
file: packages/core/tools/src/code-mode.ts
symbol: binding()（run_code 子调度路径）
issue: `registry[TOOL_RUNTIME_SCHEDULER]`（L483）在 `scheduler.prepare(input)`（L547）前无守卫
detail: code 模式下 run_code 的子工具分发走同一符号查找；符号缺失时同样抛原始
  TypeError，且发生在用户代码执行中途，abort 语义与错误归因都会失真。
suggestion: L483 取值后立即判空并抛描述性错误（同 blocker 的消息与类型）。
```

```
severity: major
file: packages/core/tools/src/index.ts
symbol: TOOL_RUNTIME_SCHEDULER (L466)
issue: unique symbol 使调度器可用性静默依赖 dsh-tools 模块实例同一性
detail: `Symbol('@deepseek-ai/dsh-tools.scheduler')` 在进程内每份 dsh-tools 模块实例
  各自生成。若同一进程混入两份 dsh-tools（跨版本模块并存：全局 rc.7 + 仓库 rc.8 +
  插件依赖），注册方与读取方持有不同 symbol，`ctx.tools[SYMBOL]` 为 undefined 且零诊断。
  本次机器上三版本并存 + 双启动路径换源重启，正是该条件的现实触发环境。
suggestion: 启动期自检：注册 ToolRuntime 时在同一模块内断言符号已存在且
  `ctx.tools` 的构造器标识一致；或在 agent-loop 侧以 `instanceof ToolRuntime`
  兜底识别（跨模块实例仍需失败的 loud 路径，而非静默 undefined）。
```

```
severity: minor
file: packages/core/session（turn/end 事件）
issue: 内部 TypeError 被归类为 code:"UNKNOWN"，且会话日志不记录堆栈
detail: 本次事故 turn/end 只落了 message+UNKNOWN，无法从日志直接定位崩溃帧，
  需要靠事件序号与源码行序反推（本审查即如此定位）。
suggestion: 内部异常（非 LlmError/ToolError 体系）映射独立 code（如 INTERNAL），
  并在 turn/end 的结构化失败中可选附带堆栈摘要。
```

```
severity: minor (operational)
file: start-dsh.ps1 / ~/.dsh/desktop-launcher/launcher.ps1
issue: 双启动路径跨版本共享 3080 端口与 ~/.dsh 会话目录
detail: 桌面启动器固定运行全局 rc.7；start-dsh.ps1 运行仓库构建并先杀旧实例。
  更新/重启窗口内不同版本进程交替服务同一会话存储，制造模块版本混用窗口
  （turn 1–3 与 turn 4 报错形态不一致即其直接证据）。
suggestion: 固定单一启动来源；全局安装与仓库版本对齐后彻底重启一次。
```

## Suggested patch

`packages/core/agent-loop/src/tool-calls.ts`（runGroup 内，startCall 定义之前；同函数 152–153 行改用同一 `scheduler` 局部变量）:

```ts
const scheduler = ctx.tools[TOOL_RUNTIME_SCHEDULER]
if (scheduler === undefined) {
  throw new Error(
    'tool scheduler is not available on ctx.tools: ensure ToolRuntime service is properly registered',
  )
}
// L169: const prepared = await scheduler.prepare(call.exec)
// L152-153: scheduler.finalize(...) / scheduler.finish(...)
```

`packages/core/tools/src/code-mode.ts`（L483 之后）:

```ts
const scheduler = registry[TOOL_RUNTIME_SCHEDULER]
if (scheduler === undefined) {
  throw new Error(
    'tool scheduler is not available on registry: ensure ToolRuntime service is properly registered',
  )
}
```

优先建议：若上游 master 已含守卫实现，直接 rebase 采用上游版本，避免消息分叉。

## Test guidance

- 新增回归用例（`packages/core/agent-loop/tests/`）：构造 `ctx.tools` 为不含该 symbol 的对象 → 断言 turn 失败消息为描述性错误而非 TypeError（现有 `resume.spec.ts`、`config-session-id.spec.ts` 展示了构造 harness 的方式）。
- 定向跑：`pnpm vitest packages/core/agent-loop packages/core/tools`。
- 上游已加守卫的话，以其测试为准对齐。

## Follow-ups

- 用户侧立即可做的恢复（非代码）：统一启动来源——要么只用 `start-dsh.cmd`（仓库构建），要么把全局包升级到与仓库同版本后再用桌面启动器；切换后完整重启，清掉混版本窗口。
- 启动期 dsh-tools 模块实例唯一性自检（issue 3 的结构性修复）。
- 会话日志考虑记录内部错误堆栈（issue 4）。

## 缺口 / 未验证项

- turn 1–3 所运行进程的确切二进制已不可考（其代码不在当前磁盘上），"13:26:56–13:27:57 之间换源重启" 是由报错形态差异 + 启动脚本行为推出的最强解释，非直接观测。
- 守卫消息的搜索覆盖了本仓库、全局 @deepseek-ai 安装、`~/.dsh/plugins|profiles|.agent-presets`；未扫描机器上其他 npm 缓存/检出。上游 pack 对象未逐一映射到具体 commit（相关 git 查询被用户中止，未继续）。

## 根因终局实证（2026-08-20 补充，用户重启后仍复现）

`createRequire('~/.dsh/profiles/web/package.json')` 实测解析：

- `@deepseek-ai/dsh-tools` → `~/.dsh/profiles/web/node_modules/@deepseek-ai/dsh-tools`（**rc.6 实体副本**）
- `@deepseek-ai/dsh-agent-loop` → `E:\UI\deepseek-harness\packages\core\agent-loop`（仓库 rc.8）

Loader 的 `baseUrl` 是 profile 目录（`packages/boot/app-boot/src/profile.ts` 模块注释），profile 自有 `node_modules` 在 parent-walk 中优先于安装回退目录 `~/.dsh/profiles/node_modules`（其 `dsh-tools` symlink 指向仓库安装）。因此 base patch 的 `tools` 行按名加载到 **rc.6** ToolRuntime（携带 rc.6 符号），而 `agent-loop` 行加载仓库 **rc.8**（读取 rc.8 符号）→ `ctx.tools[rc.8-symbol] === undefined` → 每个工具调用必抛 `Cannot read properties of undefined (reading 'prepare')`。

rc.6 副本的来源：`@anweat/dsh-browser`、`dsh-better-sidebar`、`@anionex/dsh-vision-toolkit` 三个第三方插件把 `@deepseek-ai/dsh-tools` 声明为**普通 dependencies**（设计上应为 peer，profile 的 pnpm 配置 `autoInstallPeers: false` 正是为让 peers 落到安装回退）。这违反了官方契约「in-box 插件永远来自与运行 dsh 相同的安装，绝不来自 profile 本地副本」（`resolveBundleDir` 注释），但该契约只约束 bundle 清单解析，未约束 Loader 行名的 Node 解析。

修复路径（按官方契约恢复，而非改官方代码）：

1. 删除 `~/.dsh/profiles/web/node_modules/@deepseek-ai/dsh-tools`（可再生依赖目录），解析即落回安装回退 symlink → 仓库 rc.8 单实例。
2. 将上述三个插件 package.json 中的 `@deepseek-ai/dsh-tools` 从 dependencies 移到 peerDependencies，防止下次插件安装重现遮蔽。
3. `pnpm run build`（或 `start-dsh.ps1 -ForceBuild`）使仓库守卫修复进入运行构建；重启。

已按官方代码风格落地守卫修复：`packages/core/agent-loop/src/tool-calls.ts`（runGroup 解析一次调度器 + loud 失败）、`packages/core/tools/src/code-mode.ts`（binding 同守卫），新增回归测试 `packages/core/agent-loop/tests/tool-scheduler-guard.spec.ts` 与 code-mode 用例；`pnpm vitest`（两包 725 通过）、`pnpm run typecheck`、`pnpm run lint` 全绿。

## 后续事件（同日 14:10 重建后）：aqua 皮肤插件加载失败

重建将官方 client 包升到当前源码后，`@deepseek-ai/dsh-client-ui-aqua@1.3.0`（profile 本地、npm 无此包）注册 keyed slot `settings.plugin.item` 时缺 `options.key`（校验点 `packages/client/ui-slots/src/index.ts:806`；官方卡片以 settings 命名空间为 key，`ui-settings-plugins/src/client/index.ts:149`）。profile 内 `modlens`、`dshmarket` 同 slot 注册均正确传 key，仅 aqua 落后于 API。属第三方插件滞后官方 API，非官方代码缺陷。

**复发与根治**：直接改安装产物会被 profile 的 `pnpm install` 重装冲掉（dshmarket 子进程强制 `CI=true` → pnpm 默认 frozen-lockfile，按锁精确还原）；`pnpm patch` 不支持 github: 来源。最终方案：复制 aqua 至 `~/.dsh/plugins/dsh-client-ui-aqua`（本地插件目录，与 dsh-memory-evolve 同模式），副本补 `key: "aqua"`，profile 依赖改为相对 `link:../../plugins/dsh-client-ui-aqua`——每次安装重放均为链接，补丁不可再被冲掉。manifest 无绝对路径。
