# Agent Note: 为已装插件 bundle 兼容 client-runtime 的 seed 键

Status: implemented

[English](2026-08-28-client-runtime-compat-seed.md) | 中文

## Problem

upstream 在 `be531688f3` 删除了 `packages/client/runtime`（`@deepseek-ai/dsh-client-runtime`），并把它的表面拆散进各 per-package client 模块。在该删除之前构建、已安装的第三方 web 插件，其预构建 client bundle 仍然 `require("@deepseek-ai/dsh-client-runtime/client")`，于是每个这类 entry 都以 `client-modules: require(...) missed the module table` 加载失败。

对已装 profile bundle 的扫描显示实际用量只有两个符号：`createSnapshotStore`（11 个包）和 `defineStore`（1 个包），而二者都位于已是平台 seed 词的 `@deepseek-ai/dsh-client-store` 中。

## Decision

`PLATFORM_MODULES` 增加一个 fork 本地键 `@deepseek-ai/dsh-client-runtime/client`，`getStaticModules()` 将它映射到与 `@deepseek-ai/dsh-client-store` 相同的 `ClientStore` 命名空间实例。旧说明符的 require 在启动时对冻结表解析，先于 factory 与 graph-row 查找，因此任何预构建插件 bundle 都无需改动。

`seed.ts` 中的 `satisfies Record<PlatformModule, unknown>` 钉使键、静态导入与表三者保持一致；只删键不删导入（或反之）会编译失败。

两处编辑都写明移除条件：一旦没有已装插件 bundle 再 require 该说明符即删除此键。该键是指向既有 seed entry 的别名，不是新的共享模块，也不是别名协议；`dsh.client.external` 语义不变。

## Not covered

seed 键无法满足已消解服务的消费者；这些需要服务本体（见后续章节）。`web-ui-remote-web-ui`、`web-ui-task-board`、`dsh-hud` 三个 profile entry 在其服务被桥接前曾被禁用，并在其发布者交付针对 `0.1.2-alpha.1` 构建的版本前保持禁用或部分可用。

## 后续：conversationEvents 服务别名

`conversationEvents` 客户端服务与本次迁移一样幸存为活跃的 `UiConversation.events` 注册表（`ConversationEventRegistry`，`ConversationNodeDefinition` 契约一致），只是挂载点更名。`ui-conversation` 的 client `apply` 现以旧服务名提供该活跃实例，使注入 `conversationEvents` 的删除前 bundle（例如 `@nanmicoder/dsh-agent-teams`）得以激活并通过新管线渲染，而非保持 pending。移除条件与 seed 键相同。

## 后续：apiProxy 服务适配器

服务端 `apiProxy` 服务幸存为 session-controller 的 Remote 表面。session-controller 插件现以旧服务名提供一个适配器，逐字镜像旧 `sessions.models` 契约（相同 RPC 信封、`resolveAgent` 做 session 查找、`selectionFor` 取当前选择、`buildModelCatalog` 提供 groups 与 failures、`routableProviders` 提供 routable 标志）。仅桥接了已装 bundle 消费的 `sessions.models` 一个动词；未桥接的动词会以响亮的 missing-method 错误浮出，而非静默错误应答。移除条件与 seed 键相同。
