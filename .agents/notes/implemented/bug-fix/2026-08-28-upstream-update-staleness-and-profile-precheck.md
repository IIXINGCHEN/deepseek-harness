# Agent Note: Automatic build freshness and deep composition precheck on upstream updates

Status: implemented

English | [中文](2026-08-28-upstream-update-staleness-and-profile-precheck.zh.md)

## Problem

Upstream git merges and plugin updates frequently left the Web profile service in a failing state after startup:
1. `start-dsh.ps1` self-check stage 4 checked only for the existence of build outputs (`lib/`, `dist/`), not their freshness relative to `src/`. When `git pull` updated source files or preset YAMLs, the running runtime and build artifacts remained stale, causing schema mismatches between new YAML configs and old binary code.
2. Self-check stage 5 only checked for duplicate `insert` IDs, but could not detect runtime-apply failures such as duplicate prefix route registrations (`duplicate prefix route "/sidebar/api"` when aggregate and standalone plugins are both enabled) or invalid plugin `config` options against exported `Config` schemas.
3. Shipped presets (like `presets/ptc/agent.cordis.yml`) were not regression-tested against the `Config` schema exported by `@deepseek-ai/dsh-agent-tool-presentation`.

## Decision

1. Added `Test-BuildArtifactsStale` to `start-dsh.ps1` self-check stage 4. It recursively compares timestamps of all `.ts`/`.tsx` files under `packages/`, `apps/`, and `vendor/` against the newest build artifacts in `lib/` and `dist/`. When source files are newer than build artifacts, `pnpm run build` is automatically triggered before starting the service.
2. Upgraded self-check stage 5 precheck script with deep validation:
   - Dynamic schema validation: loads each active plugin module and validates its `config` using its exported `Config` schema (skipping unevaluated `!!js` expressions).
   - Duplicate plugin mount detection: warns when multiple active entries mount the same package name, pointing out the exact entries to disable in `cordis.patch.yml` to prevent `duplicate prefix route` boot crashes.
3. Added regression test `writes tool-presentation configs the plugin schema accepts` in `packages/preset/agent-presets/tests/mount.spec.ts` to verify all shipped presets conform to plugin config schemas.

## Not covered

Third-party plugin market UI actions (such as toggling plugins) directly modify `cordis.patch.yml`. Self-check detects and warns about conflicting configurations prior to boot, but does not overwrite user configuration decisions.

## Alternatives considered

**Always run `pnpm run build` on startup.** Running a full build on every startup wastes 5-10 seconds even when no files changed. Timestamp-based staleness detection builds only when source files are actually newer.

**Hard-fail on same-name multiple mounts.** Some plugins or service adapters might intentionally support multiple instances under different entry IDs. Emitting a targeted warning with resolution steps allows legitimate configurations while making conflict resolution clear.

## Consequences

Startup self-check automatically heals stale artifacts after upstream git updates and catches configuration/schema drifts before they cause runtime boot failures. Shipped presets are permanently locked to plugin schemas via automated unit tests.
