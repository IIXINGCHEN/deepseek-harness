# Code Review — scheduler guard hardening & launcher install gates

- 日期：2026-08-20
- Scope：`diff`（全部未提交变更）
- Profile：standard / Focus：correctness / Style：full
- 审查者运行过的命令见「Verification evidence」

## Stats

- Files Modified: 4（`package.json`、`packages/core/agent-loop/src/tool-calls.ts`、`packages/core/tools/src/code-mode.ts`、`packages/core/tools/tests/code-mode.spec.ts`）
- Files Added: 4（`start-dsh.ps1` 395 行、`start-dsh.cmd` 37 行、`DSH.md` 196 行、`packages/core/agent-loop/tests/tool-scheduler-guard.spec.ts` 52 行）
- Files Deleted: 0
- New lines: 42（tracked diff）+ 680（untracked 全新文件）
- Deleted lines: 9（tracked diff）

变更分三组：

1. **tool-scheduler 守卫**：`ctx.tools`/`registry` 上 `TOOL_RUNTIME_SCHEDULER` 符号属性缺失时 fail loud（2026-08-20 版本混装符号双实例事故的加固，事故记录见 `2026-08-20-turn-prepare-crash.md`），含 2 个回归测试。
2. **启动器**：`start-dsh.ps1` 安装门禁加固（无条件 `pnpm install` + web profile 依赖/bundles 同构预检 + 官方修复路径），`start-dsh.cmd` 为双击入口包装。
3. **杂项**：`packageManager` 本地 bump 11.7.0→11.22.0；`DSH.md` 为 DSH 全局智能体规则文档（纯文档，非代码，不在 correctness 审查范围，仅确认无 secret、无宿主机路径泄漏——通过）。

## Top issues（按严重度排序）

```
severity: minor
file: start-dsh.ps1
symbol: Test-WebProfileDeps (line 342)
issue: 校验器自身的基础设施故障与"依赖缺失"混为一谈
detail: node 校验脚本崩溃（如 apps/cli/lib/bin.js 幸存而 packages/boot/app-boot/lib/index.js
  被单独清理的半清理树、或 node 异常退出）时 exit≠0，走"依赖缺失"分支：先触发一次无效的
  dsh plugin install 修复，复检仍失败后报"修复后仍存在不可解析项"，误导排障方向。
  正常路径已由 2026-08-20 自愈演练证实不受影响。
suggestion: 预检 Test-Path "$PSScriptRoot\packages\boot\app-boot\lib\index.js"，
  或约定校验脚本对基础设施错误使用独立退出码（如 exit 2）并在 PS 侧分支提示。
```

```
severity: minor
file: packages/core/agent-loop/src/tool-calls.ts / packages/core/tools/src/code-mode.ts
symbol: runGroup (tool-calls.ts:135-138) / createRunCodeTool 调度点 (code-mode.ts:485-488)
issue: 错误消息字面量在 2 个源文件 + 2 个测试文件共 4 处硬编码重复
detail: 'tool scheduler is not available on ctx.tools: ...' 在 tool-calls.ts:137、
  code-mode.ts:487 各写一次，code-mode.spec.ts:640 与 tool-scheduler-guard.spec.ts:48
  又各自断言同一字符串。任一处措辞漂移即破坏测试。与仓库"one home per fact /
  prefer symmetry"约定相悖（若刻意为可搜索性保留重复，建议注释说明）。
suggestion: 在 dsh-tools 的 TOOL_RUNTIME_SCHEDULER 附近导出共享常量
  （如 SCHEDULER_UNAVAILABLE_MESSAGE），源与测试统一引用。
```

```
severity: minor
file: package.json
symbol: packageManager
issue: 本地未提交的 pnpm 版本 bump 与上游 pin 分叉
detail: 上游 pin pnpm@11.7.0，本地改为 11.22.0。corepack 环境下即实际工具链版本；
  若随其他改动意外提交，将静默改变 CI 的 pnpm 版本。lockfileVersion 9.0 两者兼容，
  当前本机（含 start-dsh.ps1 演练）在 11.22.0 下全部工作正常。
suggestion: 二选一并落定：有意升级则单独提交并在 CI 验证；仅本地偏好则考虑用
  corepack 本地机制（COREPACK_ 系列）而非改仓库文件。
```

```
severity: minor
file: start-dsh.ps1
symbol: auto-update stash (line 239)
issue: git stash push -u 会把未跟踪的启动器自身（start-dsh.ps1/.cmd、DSH.md、本审查目录）一并暂存
detail: 运行时安全（PowerShell 启动前完整解析脚本，执行不依赖磁盘文件继续存在），
  但若 stash pop 冲突，用户文件停留在 stash 中且仅有一条控制台警告，下次启动的
  stash 流程可能再叠加一层。可恢复、非数据丢失。
suggestion: 保持行为但在 pop 失败分支补一句指引（`git stash list` / `git stash pop`
  手动恢复命令），降低用户自救成本。
```

```
severity: info
file: start-dsh.ps1 (step 5 与 step 7)
issue: 同一次运行内两个 pnpm 安装器版本不一致（11.22.0 vs 10.34.3）
detail: 仓库 install 走 PATH 的 pnpm@11.22.0；step 7 修复经 dsh plugin → spawnSync('pnpm')
  解析到 corepack shim 的 10.34.3。这是 dsh 官方命令的既有行为（profile 无 packageManager
  字段），store v11 格式兼容，演练中协同正常。仅作认知记录，无需修改。
suggestion: 无（如欲统一，属上游 dsh 行为变更）。
```

```
severity: info（follow-up，非阻塞）
file: packages/core/agent-loop/src/tool-calls.ts
issue: 仓库协作约定要求的随附产物未定
detail: AGENTS.md：非平凡变更需同 PR 附 Agent Note；"changing agent-loop requires
  updating docs/architecture.md"。本守卫是防御性局部加固、不改循环架构，
  Agent Note 豁免边界（"mechanical/local edits"）存在解释空间；建议提交前定夺。
suggestion: 提交时附简短 Agent Note 链接到 turn-prepare-crash 事故记录；
  architecture.md 无需更新（无架构面变化）为默认判断。
```

## 正确性核验结论（无 blocker / major）

- 守卫位置正确：`runGroup` 入口一次性解析符号（tool-calls.ts:135），组内全程复用局部 `scheduler`，行为与原 `ctx.tools[TOOL_RUNTIME_SCHEDULER]` 逐点等价（仅增加 undefined 检查）；code-mode 同构（code-mode.ts:485）。
- `as ToolRuntimeScheduler | undefined` 断言合法：类型面上符号属性非可选（index.ts:796 类属性），运行时缺失正是被防御的事故形态。
- code-mode 守卫抛错被 run-code 桥接捕获并以工具结果值回传（新测试断言 `isError:false` + `value.result` 为消息、`calls` 为空），无未处理 rejection。
- 测试确定性：mock adapter 驱动、事件等待 + findLast 断言、无定时器竞态；`delete` 符号键带 oxlint disable 注释，符合仓库 lint 习惯。
- 启动器：安装门禁自愈已实机演练（同时移走仓库与 profile 两层 node_modules → 一次运行 35s 内重建 935+236 包恢复 HTTP 200）；`Clear-WebPort` 仅杀 node 监听进程，非 node 进程主动拒绝；`start-dsh.cmd` 正确透传参数与退出码、失败 pause。
- 安全：无 secret、无宿主机路径硬编码（路径均由 `$PSScriptRoot`/`$env:USERPROFILE`/`DSH_HOME` 运行时推导）；代理仅本地回环地址。

## Suggested patch（可选，未应用）

仅 minor#1（基础设施故障区分），其余为约定/流程建议无代码补丁：

```powershell
# start-dsh.ps1 Test-WebProfileDeps 内，node 调用前：
$bootLib = Join-Path $PSScriptRoot 'packages\boot\app-boot\lib\index.js'
if (-not (Test-Path $bootLib)) {
  Write-Host "[start] 错误: dsh-app-boot 构建产物缺失，请以 -ForceBuild 重新构建。" -ForegroundColor Red
  return $false   # 或直接 exit 1 区分于依赖缺失
}
```

## Test guidance

- 已运行：`pnpm exec vitest run packages/core/agent-loop/tests/tool-scheduler-guard.spec.ts packages/core/tools/tests/code-mode.spec.ts` → **2 files, 93 tests passed**（2.55s）
- 提交前建议（本次审查未运行，属重型门禁）：`pnpm run typecheck`、`pnpm run lint`（涉及跨包 type import 变更）
- 启动器回归：破坏态演练流程见 `~/.claude` 会话记录（两层 node_modules 重命名 → `.\start-dsh.ps1` → HTTP 200）

## Follow-ups（非阻塞）

1. scheduler 守卫提交时的 Agent Note 定夺（见 info#6）。
2. 错误消息常量化（minor#2）。
3. `Test-WebProfileDeps` 基础设施错误分支（minor#1）。
4. `tui` profile 是否纳入启动器校验范围（当前仅 `web`，与脚本启动面一致）。
5. `DSH.md` 与用户全局规则的长期归属（放仓库根会随 diff 携带，确认是否有意入库）。
