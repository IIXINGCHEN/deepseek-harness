# Agent Note: Packaged executables serve web client roster

Status: implemented

English | [中文](2026-08-31-pkg-executable-web-client-roster.zh.md)

## Problem

A `@yao-pkg/pkg --sea` executable (the Python SDK runtime distribution, reused by the Windows desktop packaging) boots `dsh web` through the profile system. Under pkg, the profile installation-generation closure cannot use operating-system symlinks into the snapshot, so `dsh-app-boot` materializes ESM proxy packages instead: one directory per package with `entry-<n>.js` re-export stubs and a minimal `package.json`. Two facts about the proxies broke the browser surface: (1) The proxy manifest kept only `name`, `version`, `exports`, and `dsh.moduleFallback`. The client-modules scanner (`dsh-client-modules`) reads `dsh.client` from the manifest nearest the resolved row, so every dual-face package looked like a plain host package and `window.__DSH_BOOT__.entries` came out empty, causing `client-modules: HTML did not preload @deepseek-ai/dsh-client-modules/client.js`. (2) Even with the declaration present, `exports["./client"]` on a proxy resolves to the re-export stub, not the real browser bundle bytes.

## Decision

`packageProxySource` in `packages/boot/app-boot/src/profile.ts` reads the source package's `dsh.client`, and `ensureModuleProxy` copies it verbatim into the proxy manifest beside `moduleFallback`. Proxy currency checks compare the copied declaration so proxies written before this change regenerate on the next launch. When the located manifest carries `dsh.moduleFallback.targets['./client']` (a file URL), `resolveMeta` in `packages/client/modules/src/index.ts` uses that file as the row's `clientPath` (bundle bytes, revision hash, combo serving, HMR watch). Installs without module fallback are unaffected.

## Alternatives considered

- **Ship client bundles as raw static files outside pkg snapshot**: Rejected: breaks the self-contained single executable distribution guarantee and increases asset distribution complexity.
- **Eval browser scripts through host IPC instead of module loader**: Rejected: violates the dual-face architecture where the browser loads ES modules natively through the combo serving endpoint.

## Consequences

- The Windows desktop single-file package serves the complete web client bundle without external node_modules or broken client roster entries.
- Browser entry initialization `window.__DSH_BOOT__.entries` discovers all 46 registered UI client packages under pkg execution.
- Runtime closure manifest (`python/sdk-runtime/package.json`) includes required peer dependencies `@deepseek-ai/dsh-session-title-llm` and `@deepseek-ai/dsh-util-workspace-path`.
