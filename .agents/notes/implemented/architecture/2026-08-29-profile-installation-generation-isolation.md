# Agent Note: Installation-generation isolation for profile module fallbacks

Status: implemented

English | [中文](2026-08-29-profile-installation-generation-isolation.zh.md)

## Problem

Every dsh installation sharing a Harness home healed one flat, cross-profile directory — `$DSH_HOME/profiles/node_modules` — to its own dependency closure, last writer wins. The composed tree anchored `baseUrl` at the profile root, so every row of the tree (bundle rows, user-patch rows, and agent-preset rows through the preset mount's recorded base) resolved through that one shared directory. A second, older installation launching against the same home rewrote the closure underneath the first: a preset selecting `mode: ptc` failed its schema validation against the old installation's pre-rename plugin. The freshness check (`moduleFallbackEntryCurrent`) compared link text verbatim, so an equivalently spelled link churned the cross-process lock on every launch, and a same-directory race between two installations had no structural defense.

## Decision

The installation dependency closure is **per profile and per installation generation**. A profile gains a `.dsh-generations/<installation id>/` directory where `<installation id>` = `installationGenerationId(installAnchor)` — a slug of the canonicalized installation directory plus a short SHA-256 — and holds:

- the composed tree's empty root config (`cordis.yml`), which `prepareProfile` rewrites on every launch as before, now into the generation directory. `boot()` anchors `ctx.baseUrl` at the root config's directory, so the whole tree — and the preset mount's recorded base with it — resolves installation-first through `<generation>/node_modules`;
- the healed closure (`<generation>/node_modules`), where `healProfilesModuleFallback` now writes its links (symlinks, or ESM proxies under a packaged executable) under a per-generation cross-process lock.

`healProfilesModuleFallback` requires the loaded profile (the `home` option is gone — every consumer moved to the loaded profile: the CLI preset e2e, the web test scaffold, and the `start-dsh` preflight), and `profileGenerationDir(profile, installAnchor)` is the one computation of the directory shared by the healer, the boot, and the config dump. The old flat `$DSH_HOME/profiles/node_modules` is no longer written; it remains in the Node parent-walk after the profile's own `node_modules` as a legacy slot that existing out-of-tree installs and their pnpm overrides may still read, and the launcher no longer owns it. Supersedes the resolution paragraph of [profile plugin bundles](2026-08-05-profile-plugin-bundles.md); the `.dsh-module-fallback` bundle-only projection is unchanged.

## Alternatives considered

- **Keep the shared directory, fail loud on generation mismatch**: an old installation is the writer that poisons the state, and it cannot be taught to check a marker it predates — the defense has to move the state out of the path old binaries write.
- **Anchor preset rows at the installation itself** (resolve `@deepseek-ai/*` from the install dir): fixes preset rows only, leaves the rest of the composed tree on the shared directory, and needs a new cross-package seam to carry the installation path into `agent-presets`. Moving the root config moves every row's base at once with no new seam.

## Consequences

- Two dsh installations sharing a Harness home can no longer rewrite each other's dependency closure; the PTC-mode failure class — a preset row loading another installation's plugin — is closed structurally, not by hygiene.
- Each profile accumulates one small directory (closure links only) per installation that ever ran it; stale generations of removed installations are inert residue and safe to delete by hand.
- Community plugins' harness-peer imports still end in the legacy shared slot when the profile's `node_modules` lacks the package; that skew predates this change and is unchanged.
