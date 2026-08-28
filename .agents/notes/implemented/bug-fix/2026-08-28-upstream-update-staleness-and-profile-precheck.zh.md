# Agent Note: 官方仓库更新时自动检测构建产物新鲜度与组合深度预检

Status: implemented

[English](2026-08-28-upstream-update-staleness-and-profile-precheck.md) | 中文

## 问题

上游官方仓库拉取更新及插件更新经常导致 Web profile 服务启动失败：
1. `start-dsh.ps1` 启动脚本的自检第 4 步仅检查产物（`lib/`、`dist/`）是否存在，而不检查相对 `src/` 的新鲜度。当 `git pull` 更新了源码或 preset YAML 时，构建产物保持陈旧，导致新数据与旧代码之间产生 schema 不匹配等漂移。
2. 自检第 5 步仅检查是否存在重复的 `insert` ID，无法照到加载（apply）期崩溃，例如重复路由前缀注册（聚合包与 standalone 同时启用导致 `duplicate prefix route "/sidebar/api"`）或插件 `config` 违反导出的 `Config` schema。
3. 内置 preset（如 `presets/ptc/agent.cordis.yml`）缺少自动化回归测试来校验其配置是否符合 `@deepseek-ai/dsh-agent-tool-presentation` 导出的 `Config` schema。

## 决策

1. 在 `start-dsh.ps1` 自检第 4 步中引入 `Test-BuildArtifactsStale` 函数，递归对比 `packages/`、`apps/` 和 `vendor/` 下所有 `.ts`/`.tsx` 源码与 `lib/`/`dist/` 产物的最新修改时间。一旦发现源码新于产物，启动前自动执行 `pnpm run build`。
2. 升级自检第 5 步预检脚本，实现深度组合校验：
   - 动态 schema 校验：加载各启用插件模块，使用其导出的 `Config` schema 校验条目 `config`（跳过未求值的 `!!js` 表达式）。
   - 同名插件多挂载检测：当检测到同一插件包被多个启用条目同时挂载时输出明确警告与 `cordis.patch.yml` 修复指引，提前消除 `duplicate prefix route` 崩溃隐患。
3. 在 `packages/preset/agent-presets/tests/mount.spec.ts` 中新增回归测试 `writes tool-presentation configs the plugin schema accepts`，锁定内置 preset 对插件 config schema 的一致性。

## 未覆盖

第三方插件市场 UI 的开关操作直接修改 `cordis.patch.yml`。自检能够在启动前发现并警告冲突配置，但不会静默强行覆盖用户的配置决定。

## 替代方案

**每次启动无条件执行 `pnpm run build`。** 每次启动都完整构建会在无改动时浪费 5-10 秒。基于时间戳的新鲜度检测仅在源码确实更新时才触发构建。

**对同名多挂载直接致命报错（exit 1）。** 某些特殊插件可能合法支持多实例挂载。采用精确警告并给出禁用建议的方式既保留灵活性，又让冲突修复路径清晰可见。

## 后果

启动自检能够在上游 git 更新后自动自愈陈旧产物，并在启动前拦截配置与 schema 漂移。内置 preset 与插件 schema 的一致性通过单测实现强约束。
