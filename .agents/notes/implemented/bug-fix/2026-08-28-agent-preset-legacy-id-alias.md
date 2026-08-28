# Agent Note: Legacy agent-preset id alias for sessions logged before a rename

Status: implemented

English | [中文](2026-08-28-agent-preset-legacy-id-alias.zh.md)

## Problem

`3ca9c7d489` renamed the PTC preset's id from `code` to `ptc` and deliberately left session-persistent vocabulary untouched: the rename commit states the stacked session-persistence migration is a separate change. Every session created before the rename carries `agentPreset: "code"` in its `agentPreset` projection, and the resume path resolves that stored id — `composeAgent` reads the projection and calls `agentPresets.resolve("code")`, which threw `UnknownPresetError`. The user-visible result: switching such a session to PTC mode failed with `preset "code" not found (available: standard, ptc, minimal, cordis, …)` on every deployment that upgraded, including this fork's installed web profile.

## Decision

`AgentPresets.resolve` gained a fallback translation table, `LEGACY_PRESET_IDS`, currently one row: `code → ptc`. The lookup order is real-id first, legacy translation second: a root that still supplies a preset literally named `code` keeps winning, so the table can never shadow a deployment's own preset. When neither the requested id nor its translation resolves, the thrown `UnknownPresetError` names the requested id, never the translation, so error text stays meaningful to the caller.

The translation is faithful, not a guess: the rename commit deleted `presets/code/preset.yml` and created `presets/ptc/` with the same composition and the same display name (「PTC 模式」), so a session recorded under `code` resumes under the identical composition the rename left behind. `resolveMountable` and the standing-mount path inherit the behavior through `resolve`, and a resumed session still logs its own stored id — model-visible state stays logged and nothing rewrites durable sessions.

Removal condition: drop the `code` row once the session-persistence migration for the renamed vocabulary lands and no on-disk session projection records `code` anymore.

## Not covered

Sessions recorded under an id that was retired without a successor still fail with the original error; the table only maps renames with an unambiguous target. The UI preset picker is unchanged — it lists current ids from `list()`, which never consults the table, so authored presets and the roster surface behave exactly as before.

## Alternatives considered

**Migrate the stored projections instead.** Rewriting every logged `agentPreset: "code"` to `"ptc"` would remove the need for the alias, but it edits durable model-visible state: the fail-closed session-event vocabulary policy makes any structural rewrite a `SESSION_FORMAT_VERSION` change, and the rename commit itself deferred exactly this to the stacked persistence PR. It also fixes one deployment's sessions, not the class.

**Ship a user-root preset named `code`.** A `code` directory in the harness-home user root would resolve the old id with no code change. It loses because it is per-home configuration that duplicates the shipped composition, drifts from `ptc` the next time the composition changes, and does nothing for any other deployment upgrading across the rename.

**Keep failing with a migration hint.** Leaving the resume error in place (upstream's implicit choice for now) and telling the user to recreate the session preserves strict id honesty. It loses because the session is recoverable — the composition it names still exists under a new id — so a hard failure destroys value the alias preserves at one table row.

## Consequences

The trade-off cost: a second id spelling now resolves to `ptc`, so a caller that mistypes a genuinely intended custom preset named something like `code` gets the renamed preset while a root still defines it — impossible today because a real `code` root wins, but the invariant to keep when editing the table is real-id-first. The error text continues to name the requested id, so unresolved lookups read the same as before.

What it bought: every session logged before the rename resumes under the composition it actually ran, which restores PTC mode switching for existing sessions without touching durable state. The fix rides the same fork-local compat seam as the client-runtime seed and the apiProxy adapter, and the `code` row names its own removal condition so the table cannot outlive its migration.
