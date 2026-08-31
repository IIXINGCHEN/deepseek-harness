/**
 * Regression for the missing-scheduler incident: a `tools` service whose
 * registry lacks the symbol-keyed scheduler view (unregistered ToolRuntime, or
 * a version-mixed module instance minting a different symbol) fails the turn
 * with a descriptive error instead of a raw TypeError on `.prepare`.
 * @module dsh-agent-loop/tests/tool-scheduler-guard
 */

import { describe, expect, it } from 'vitest'
import { Context } from '@deepseek-ai/cordis'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import LlmRuntime from '@deepseek-ai/dsh-llm'
import SessionStore, { SessionId } from '@deepseek-ai/dsh-session'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime, { SCHEDULER_UNAVAILABLE_MESSAGE, TOOL_RUNTIME_SCHEDULER } from '@deepseek-ai/dsh-tools'
import AgentRegistry from '@deepseek-ai/dsh-agent'
import SessionProjectionRegistry from '@deepseek-ai/dsh-session-projection'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { MockAdapter, toolCallResponse } from './mock-adapter.ts'

describe('tool scheduler guard', () => {
  it('fails a tool-call turn with a descriptive error when ctx.tools lacks the scheduler symbol', async () => {
    const adapter = new MockAdapter([toolCallResponse('call_1', 'echo', { value: 'x' })])
    const ctx = new Context()
    await ctx.plugin(LlmRuntime)
    await ctx.plugin(SessionStore)
    await ctx.plugin(SessionProjectionRegistry)
    await ctx.plugin(SystemPrompt)
    await ctx.plugin(ToolRuntime)
    await ctx.plugin(AgentRegistry)
    await ctx.plugin(AgentLoop, { agents: [] })
    ctx.llm.registerAdapter(['mock'], adapter)

    const agent = ctx.agentLoop.create(SessionId('scheduler-guard'), { provider: 'mock', model: 'mock' })
    // The incident shape: the service is live and enumerable, but the
    // symbol-keyed scheduler view is missing from the registry instance.
    // oxlint-disable-next-line typescript/no-dynamic-delete -- incident fixture: drop the symbol-keyed view the guard must detect
    delete (ctx.tools as unknown as Record<symbol, unknown>)[TOOL_RUNTIME_SCHEDULER]

    const idle = new Promise<void>((resolve) => {
      const dispose = ctx.on('agent/status', ({ agent: subject, status }) => {
        if (subject === agent && status === 'idle') { dispose(); resolve() }
      })
    })
    agent.followup(createUserMessage({ content: [{ type: 'text', text: 'run the tool' }], source: { kind: 'user' } }))
    await idle

    expect(agent.session.events.findLast(event => event.type === 'turn/end')?.data.reason).toMatchObject({
      kind: 'error',
      error: { message: SCHEDULER_UNAVAILABLE_MESSAGE },
    })
    await ctx.fiber.dispose()
  })
})
