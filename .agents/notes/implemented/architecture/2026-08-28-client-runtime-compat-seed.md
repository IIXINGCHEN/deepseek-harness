# Agent Note: Client-runtime compatibility seed key for installed plugin bundles

Status: implemented

English | [中文](2026-08-28-client-runtime-compat-seed.zh.md)

## Problem

Upstream removed `packages/client/runtime` (`@deepseek-ai/dsh-client-runtime`) in `be531688f3` and dissolved its surface into per-package client modules. Installed third-party web plugins built before that removal still `require("@deepseek-ai/dsh-client-runtime/client")` in their prebuilt client bundles, so every such entry failed to load with `client-modules: require(...) missed the module table`.

A sweep of the installed profile bundles found the actual usage surface is two symbols: `createSnapshotStore` (11 packages) and `defineStore` (1 package). Both live in `@deepseek-ai/dsh-client-store`, which is already a platform seed word.

## Decision

`PLATFORM_MODULES` gains one fork-local key, `@deepseek-ai/dsh-client-runtime/client`, and `getStaticModules()` maps it to the same `ClientStore` namespace instance as `@deepseek-ai/dsh-client-store`. A require of the old specifier resolves against the frozen table at boot, before factory or graph-row lookups, so no prebuilt plugin bundle changes.

The `satisfies Record<PlatformModule, unknown>` pin in `seed.ts` keeps the key, the static import, and the table in lockstep; removing the key without removing the import (or vice versa) fails to compile.

Both edits carry removal conditions: drop the key once no installed plugin bundle requires the specifier. The key is an alias to an existing seed entry, not a new shared module and not an alias protocol; `dsh.client.external` semantics are unchanged.

## Not covered

The seed key cannot satisfy consumers of dissolved services; those need the service itself (see the follow-ups). The `web-ui-remote-web-ui`, `web-ui-task-board`, and `dsh-hud` profile entries were disabled until their services were bridged, and stay disabled or partial until their publishers ship versions built against `0.1.2-alpha.1`.

## Follow-up: conversationEvents service alias

The `conversationEvents` client service survived the same migration as the live `UiConversation.events` registry (`ConversationEventRegistry`, identical `ConversationNodeDefinition` contract) under a new mount point. `ui-conversation`'s client `apply` now provides that live instance under the old service name, so pre-removal bundles injecting `conversationEvents` (for example `@nanmicoder/dsh-agent-teams`) activate and render through the new pipeline instead of staying pending. Same removal condition as the seed key.

## Follow-up: apiProxy service adapter

The server-side `apiProxy` service survived as the session-controller Remote surface. The session-controller plugin now provides the old service name backed by an adapter that mirrors the old `sessions.models` contract (same RPC envelope, `resolveAgent` for session lookup, `selectionFor` for the current selection, `buildModelCatalog` for groups and failures, `routableProviders` for the routable flag). Only `sessions.models` is bridged — the verb the installed bundles consume; unbridged verbs surface as loud missing-method errors rather than silent wrong answers. Same removal condition as the seed key.
