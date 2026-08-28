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

## Alternatives considered

**Reimplement a fork-local `@deepseek-ai/dsh-client-runtime` package.** A compat package would answer any require of the removed module, but the installed-bundle sweep found the consumed surface is two symbols that `dsh-client-store` already exports, so a new shared module (its own publish, lint, and supply-chain surface) buys nothing the seed alias does not.

**Leave pre-removal bundles pending until their publishers rebuild.** Doing nothing keeps `web-ui-remote-web-ui`, `web-ui-task-board`, and `dsh-hud` disabled and every bundle that requires the old specifier or injects the old service names unloadable — accurate, but it blocks this deployment's UI on third-party release schedules for identifiers whose surviving surface is intact and bridged in one line each.

**Re-add the whole removed `apiProxy` surface.** Mirroring every verb of the dissolved service would preserve full API compatibility; the note rejects it because only `sessions.models` is consumed and silent wrong answers for unbridged verbs are worse than loud ones, so the adapter bridges exactly the consumed verb.

## Consequences

The cost: the frozen module table now carries a key that names no package, and the profile keeps disabled entries whose return depends on bridges landing — each with a removal condition that requires re-sweeping installed bundles before deletion. Unbridged verbs of a compat name fail loudly rather than answering, which surfaces as errors from old bundles until a verb is bridged on purpose.

What it bought: prebuilt plugin bundles load unchanged against the renamed runtime, the conversation registry and the session-models surface answer their old names, and the services the 2026-08 merge dissolved are reachable again one consumed verb at a time — with the `satisfies` pin and per-bridge removal conditions keeping the seam deletable rather than permanent.
