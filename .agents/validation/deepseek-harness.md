# Validate: deepseek-harness

- 日期：2026-08-20
- 触发：`/validation:code-review-fix` 收尾（审查报告 `.agents/code-reviews/2026-08-20-scheduler-guard-and-start-script.md`）
- 改动面：`packages/core/tools`（新增导出常量 + code-mode 守卫引用）、`packages/core/agent-loop`（tool-calls 守卫引用 + 守卫测试）、两个测试文件、`start-dsh.ps1`（构建门禁 + stash 指引）
- 证据匹配原则：仓库 AGENTS.md「Match evidence to the surface」——不默认全量套件，CI 拥有穷尽覆盖

## Validation Summary

- **Status**: PASS
- **Total Checks**: 7
- **Passed**: 7
- **Failed**: 0
- **Execution Time**: ~5 min（typecheck 占 ~4.5 min）

## Validation Results

### 1. Syntax & Linting

**Command:**
```bash
pnpm exec tsx scripts/run-oxlint.ts packages/core/tools packages/core/agent-loop
powershell -NoProfile -Command '<Parser::ParseFile start-dsh.ps1>'
```

**Result:** PASS（oxlint exit=0、零输出=无发现；PS 解析 PARSE_OK）

### 2. Type Checking

**Command:**
```bash
pnpm run typecheck   # = build:lib:host (tsc -b tsconfig.host.json + tsdown) + tsc -b tsconfig.client.json
```

**Result:** PASS（exit 0；host 面全部包构建完成，含新增导出经 tsdown 打包）

### 3. Unit Tests

**Command:**
```bash
pnpm exec vitest run packages/core/agent-loop/tests/tool-scheduler-guard.spec.ts packages/core/tools/tests/code-mode.spec.ts
```

**Result:** PASS — `Test Files 2 passed (2) / Tests 93 passed (93)`（2.49s；常量化重构前后各跑一轮均 93/93）

### 4. Integration / Smoke（启动器端到端）

**Command:**
```bash
powershell -ExecutionPolicy Bypass -File ./start-dsh.ps1   # 健康路径
```

**Result:** PASS — HTTP 200（~3s 轮询内恢复）；新增 `$bootLib` 构建门禁未误触发（无「正在构建」输出）；旧实例端口替换正常。构建门禁负分支（lib 缺失→触发重建）为逻辑等价的条件项，未单独演练（需数分钟全量构建），已按正向路径验证。

### 5. Build Validation

**Command:** 与 Type Checking 同（build:lib:host 覆盖全部改动包）。

**Result:** PASS。完整 `pnpm run build`（client/web 面 + web 前端）未运行：本 diff 不触及这些面。

### 6. 导出文档门禁（仓库特有）

**Command:** `pnpm exec tsx scripts/verify-export-jsdoc.ts`

**Result:** PASS — `every exported name in each package API is documented`（新增 `SCHEDULER_UNAVAILABLE_MESSAGE` 的 JSDoc 合规）

### 7. 单一来源核验

**Command:** `grep -rn "tool scheduler is not available" packages/ --include="*.ts"`

**Result:** PASS — 仅 `packages/core/tools/src/index.ts:474` 常量定义一处；源码 2 处与测试断言 2 处均改引常量。

## Issues Found

### Critical / High / Medium / Low

- 无（本轮修复未引入新问题）

### 有意不修复项（来自审查报告，非缺陷）

- [minor#3] `package.json` `packageManager` 本地 bump 的去留 = 用户决策项
- [info#6] Agent Note 随附 = PR 提交时事项（仓库约定）

## Recommendations

- PR 提交时附 Agent Note 链接 `.agents/code-reviews/2026-08-20-turn-prepare-crash.md`
- 提交前若走 CI，可补跑 `pnpm run hygiene`（本机已覆盖其 JSDoc 子项）

## Next Steps

1. 变更就绪可提交（用户未要求 commit，未执行）
2. 剩余两项决策见上
