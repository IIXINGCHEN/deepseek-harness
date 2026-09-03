# Agent Note: 打包可执行文件服务 Web 客户端花名册

Status: implemented

[English](2026-08-31-pkg-executable-web-client-roster.md) | 中文

## 问题

`@yao-pkg/pkg --sea` 可执行文件（Python SDK 运行时发行版，被 Windows 桌面打包复用）通过 profile 系统引导 `dsh web`。在 pkg 下，profile 安装代闭包无法使用指向快照的操作系统符号链接，因此 `dsh-app-boot` 实体化 ESM 代理包：每个包一个目录，包含 `entry-<n>.js` 重导出桩和最小化 `package.json`。代理的两个事实破坏了浏览器界面：(1) 代理清单仅保留了 `name`、`version`、`exports` 和 `dsh.moduleFallback`。客户端模块扫描器（`dsh-client-modules`）从最靠近解析行的清单中读取 `dsh.client`，导致每个双面包看起来都像纯宿主包，`window.__DSH_BOOT__.entries` 变为空，报 `client-modules: HTML did not preload @deepseek-ai/dsh-client-modules/client.js`。(2) 即使声明存在，代理上的 `exports["./client"]` 也会解析到重导出桩，而不是真实的浏览器 bundle 字节。

## 决策

`packages/boot/app-boot/src/profile.ts` 中的 `packageProxySource` 读取源包的 `dsh.client`，`ensureModuleProxy` 将其逐字复制到代理清单中的 `moduleFallback` 旁。代理新鲜度检查会比较复制的声明，从而在此变更前写入的代理会在下次启动时自动重新生成。当定位到的清单携带 `dsh.moduleFallback.targets['./client']`（文件 URL）时，`packages/client/modules/src/index.ts` 中的 `resolveMeta` 将该文件用作行的 `clientPath`（bundle 字节、版本哈希、组合服务、HMR 监听）。没有模块回退的安装不受影响。

## 备选方案

- **将客户端 bundle 作为 pkg 快照外部的原始静态文件分发**: 否决：破坏了自包含单可执行文件分发的完整性承诺，增加了资源管理复杂度。
- **通过宿主 IPC 评估浏览器脚本而非模块加载器**: 否决：违反了浏览器通过组合服务接口原生加载 ES 模块的双面架构。

## 后果

- Windows 桌面单文件安装包无需外部 node_modules 即可完整提供 Web 客户端 bundle，无花名册条目丢失。
- 浏览器入口初始化 `window.__DSH_BOOT__.entries` 在 pkg 运行环境下正确发现所有 46 个已注册 UI 客户端包。
- 运行时闭包清单（`python/sdk-runtime/package.json`）补齐了所需的对等依赖 `@deepseek-ai/dsh-session-title-llm` 与 `@deepseek-ai/dsh-util-workspace-path`。
