# Agent Note: An inherited reasoning effort never fails the turn

Status: implemented

English | [中文](2026-08-26-inherited-reasoning-effort-never-fails-turn.zh.md)

## Problem

A session failed every turn with `UNSUPPORTED_REASONING_EFFORT: provider "vision-toolkit-oxa" model "stealth/ox-alpha" does not support reasoning effort "off"`, and an earlier fix round (20260826-174500) that stripped a stale effort on route switch did not stop it. Verified against the deployment: `settings.yaml` carried `agent-default-model: {provider: vision-toolkit-oxa, model: stealth/ox-alpha, reasoningEffort: off}`, and the model is a hand-declared llm-pi-ai route entry without `reasoningEfforts`, so the adapter reports no reasoning capability at all — `LlmRuntime.resolveCallWithInfo` rejects any requested effort for such a model, `off` included. The saved triple reached every new session verbatim: the web gateway seeds its per-session selection from the agent default when the log names no header (`selectionFor().current`), and the headless bundle seeds `installModelSelection` the same way, so the stale effort was applied as if a user had picked it and the first `prepareCall` failed the turn.

Three paths could deliver an inherited effort to an incompatible model: a stale saved default selection (catalog or profile changed after the save, or a hand-edited settings document), a same-route capability change that invalidates an already-logged explicit effort, and any `agent/request` waterfall listener forwarding a value chosen for another model. The route-switch guard cannot fire on any of them when the provider and model are unchanged. Live selections are a different tier: `session.selectModel` resolves the exact route before accepting a switch, so an unsupported effort picked live is refused at the RPC with `model-unavailable` — that contract is correct and unchanged.

## Decision

`ReactLoopAgent.buildRequest` owns the boundary between inherited and live effort values. When `prepareCall` rejects the proposal with `UNSUPPORTED_REASONING_EFFORT` and the config carries an effort, the loop drops the effort, logs a warning naming the route and the dropped value, and prepares once more; the model's own default then applies and the turn runs. Because every live selection was validated when it was made, the only efforts that can reach this guard are inherited ones — a persisted header value, a saved default selection, or a plugin proposal — so dropping to the model default never overrides a live user choice. A dropped effort that a poisoned source re-injects on a later step is dropped again; each drop warns, keeping the condition observable in logs until the selection is re-picked. The second preparation is not wrapped in recovery: after the drop the config names no effort, so a repeated rejection means the adapter's own default is inconsistent with its declared efforts, which is adapter metadata trouble `resolveCallWithInfo` already owns.

Two supporting seams complete the isolation. The web gateway's `selectionFor().current` no longer copies an adapter-materialized default out of the logged header as an explicit selection: when `adapterDefaults.reasoningEffort` marks the value as adapter-owned, the selection reports no effort, mirroring what `requestProposal` already does for the loop's own seed — otherwise the next same-route pick would pin the model's default as if the user chose it. And the seed guard from the 20260826-174500 round stays: a loop instance restores an explicit effort only when the logged header names its declared route, and a route change in the `agent/request` waterfall drops an effort inherited unchanged. Together the three layers mean an effort crosses into a request only as a still-supported explicit choice, a waterfall override, or a model's own default.

## Alternatives considered

**Clamp or alias the effort inside `resolveCallWithInfo`.** Rejected: that method's documented contract validates a caller-supplied value with no clamping or aliasing, and both `resolveCallConfig` consumers (live selection, standalone queries) rely on the rejection. The loop knows the value was inherited; the resolver does not.

**Normalize inside `installModelSelection`.** Rejected: the model-selection seam would need exact-model capability lookups on every request, coupling it to the LLM runtime it does not own, and agents without an installed selection (subagent compositions, direct `AgentLoop` consumers) would keep the failure.

**Fail loud and require fixing `settings.yaml`.** Rejected as the runtime behavior: a stale persisted triple would make every new session unusable until manual document surgery, while the composer's effort pane already offers the correct levels for the selected model. The warning log keeps the condition visible for the operator.

## Consequences

An inherited effort that the exact model cannot serve degrades to the model default with one warning per affected request instead of failing the turn; the `request/header` then records the materialized default with its `adapterDefaults` marker, and the next step's proposal strips it again, so the log stays reconstructable. `session.selectModel` still rejects a live unsupported pick, and `resolveCallConfig` keeps its reject-before-I/O contract. A session poisoned by a stale saved default keeps warning on every step until the user re-picks a model, which updates the saved triple through the validated path. The `agent-default-model` service is unchanged: its document remains a snapshot of a past validated selection, and consumers no longer treat it as live-validated input.
