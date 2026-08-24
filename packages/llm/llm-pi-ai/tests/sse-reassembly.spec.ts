import { afterEach, describe, expect, it } from 'vitest'
import { openAIResponsesApi } from '@earendil-works/pi-ai/api/openai-responses.lazy'
import type { Context as PiContext, Model } from '@earendil-works/pi-ai'
import { installSseReassembly, reassembleSplitSseEvents, reassemblyOrigins } from '../src/sse-reassembly.ts'

const COMPLETED: unknown = {
  type: 'response.completed',
  response: {
    id: 'resp_test', object: 'response', status: 'completed',
    output: [{ type: 'reasoning', id: 'rs_1', summary: [], content: [{ type: 'reasoning_text', text: `项目必须使用 dsh-context7 ${'x'.repeat(900)}` }] }],
    usage: { input_tokens: 168, output_tokens: 64, input_tokens_details: { reasoning_tokens: 64 } },
  },
}
const COMPLETED_JSON = JSON.stringify(COMPLETED)

/** A stream that emits the given byte strings as separate read chunks. */
function byteStream(parts: readonly string[]): ReadableStream<Uint8Array> {
  const enc = new TextEncoder()
  let i = 0
  return new ReadableStream<Uint8Array>({
    pull(controller) {
      if (i >= parts.length) controller.close()
      else controller.enqueue(enc.encode(parts[i++]))
    },
  })
}

async function drain(stream: ReadableStream<Uint8Array>): Promise<string> {
  const dec = new TextDecoder()
  let out = ''
  const reader = stream.getReader()
  for (;;) {
    const { done, value } = await reader.read()
    if (done) return out
    out += dec.decode(value, { stream: true })
  }
}

const MOCK_MODEL: Model<'openai-responses'> = {
  id: 'Qwen/Qwen3.8-27B-FP8',
  name: 'Qwen 3.8',
  provider: 'vision-toolkit-empero',
  api: 'openai-responses',
  baseUrl: 'https://relay.test/v1',
  reasoning: false,
  input: ['text'],
  contextWindow: 32768,
  maxTokens: 4096,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
}
const MOCK_CONTEXT: PiContext = { messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }], timestamp: 0 }] }

describe('reassembleSplitSseEvents unit tests', () => {
  it('passes well-formed event bytes through unchanged across chunk splits', async () => {
    const wire = 'event: response.completed\ndata: ' + COMPLETED_JSON + '\n\n'
      + 'event: response.output_text.delta\ndata: {"delta":"hi"}\n\n'
      + 'data: [DONE]\n\n'
    const out = await drain(reassembleSplitSseEvents(byteStream([wire.slice(0, 40), wire.slice(40, 900), wire.slice(900)])))
    expect(out).toBe(wire)
  })

  it('passes well-formed CRLF-framed bytes through unchanged', async () => {
    const wire = 'event: response.completed\r\ndata: ' + COMPLETED_JSON + '\r\n\r\n'
    expect(await drain(reassembleSplitSseEvents(byteStream([wire])))).toBe(wire)
  })

  it('supports CR-CR frame terminators', async () => {
    const wire = 'event: response.completed\rdata: ' + COMPLETED_JSON + '\r\r'
    expect(await drain(reassembleSplitSseEvents(byteStream([wire])))).toBe(wire)
  })

  it('reassembles an event that carried no explicit event name', async () => {
    const wire = 'data: ' + COMPLETED_JSON.slice(0, 500) + '\n\n'
      + 'data: ' + COMPLETED_JSON.slice(500) + '\n\n'
    expect(await drain(reassembleSplitSseEvents(byteStream([wire])))).toBe('data: ' + COMPLETED_JSON + '\n\n')
  })

  it('flushes held partial when followed by [DONE] or corrupt frame', async () => {
    const cut = 500
    const wireDone = 'event: response.completed\ndata: ' + COMPLETED_JSON.slice(0, cut) + '\n\ndata: [DONE]\n\n'
    expect(await drain(reassembleSplitSseEvents(byteStream([wireDone])))).toBe(wireDone)

    const wireCorrupt = 'event: response.completed\ndata: ' + COMPLETED_JSON.slice(0, cut) + '\n\ndata: {bad: syntax}\n\n'
    expect(await drain(reassembleSplitSseEvents(byteStream([wireCorrupt])))).toBe(wireCorrupt)

    const wireJoinedCorrupt = 'event: response.completed\ndata: ' + COMPLETED_JSON.slice(0, cut) + '\n\ndata: broken"}\n\n'
    expect(await drain(reassembleSplitSseEvents(byteStream([wireJoinedCorrupt])))).toBe(wireJoinedCorrupt)
  })

  it('handles empty-data lines and structural truncation', async () => {
    const structTrunc = 'data: {"a": {"b":\n\ndata: 1}}\n\n'
    expect(await drain(reassembleSplitSseEvents(byteStream([structTrunc])))).toBe('data: {"a": {"b":1}}\n\n')

    const emptyLine = 'data:\n\n'
    expect(await drain(reassembleSplitSseEvents(byteStream([emptyLine])))).toBe(emptyLine)
  })

  it('handles data and event fields without leading spaces', async () => {
    const wire = 'event:response.completed\ndata:' + COMPLETED_JSON.slice(0, 500) + '\n\n'
      + 'data:' + COMPLETED_JSON.slice(500) + '\n\n'
    expect(await drain(reassembleSplitSseEvents(byteStream([wire])))).toBe('event: response.completed\ndata: ' + COMPLETED_JSON + '\n\n')
  })

  it('forwards malformed JSON corruption that is not truncation immediately', async () => {
    const corrupt = 'event: error\ndata: {unquoted_broken: true}\n\n'
    expect(await drain(reassembleSplitSseEvents(byteStream([corrupt])))).toBe(corrupt)
  })

  it('flushes non-terminated pending bytes at stream end', async () => {
    const incomplete = 'data: partial'
    expect(await drain(reassembleSplitSseEvents(byteStream([incomplete])))).toBe(incomplete)
  })

  it('flushes a held frame when stream closes without continuation', async () => {
    const cut = 500
    const wire = 'event: response.completed\ndata: ' + COMPLETED_JSON.slice(0, cut) + '\n\n'
    expect(await drain(reassembleSplitSseEvents(byteStream([wire])))).toBe(wire)
  })

  it('reassembles a payload the relay split into two events', async () => {
    const cut = 700
    const wire = 'event: response.completed\ndata: ' + COMPLETED_JSON.slice(0, cut) + '\n\n'
      + 'data: ' + COMPLETED_JSON.slice(cut) + '\n\n'
      + 'data: [DONE]\n\n'
    const out = await drain(reassembleSplitSseEvents(byteStream([wire.slice(0, 100), wire.slice(100)])))
    expect(out).toBe('event: response.completed\ndata: ' + COMPLETED_JSON + '\n\ndata: [DONE]\n\n')
  })

  it('reassembles a payload the relay split into three segments', async () => {
    const a = COMPLETED_JSON.slice(0, 300)
    const b = COMPLETED_JSON.slice(300, 999)
    const c = COMPLETED_JSON.slice(999)
    const wire = 'event: response.completed\ndata: ' + a + '\n\ndata: ' + b + '\n\ndata: ' + c + '\n\n'
    const out = await drain(reassembleSplitSseEvents(byteStream([wire])))
    expect(out).toBe('event: response.completed\ndata: ' + COMPLETED_JSON + '\n\n')
  })

  it('joins across a continuation segment that repeats the event name', async () => {
    const cut = 500
    const wire = 'event: response.completed\ndata: ' + COMPLETED_JSON.slice(0, cut) + '\n\n'
      + 'event: response.completed\ndata: ' + COMPLETED_JSON.slice(cut) + '\n\n'
    const out = await drain(reassembleSplitSseEvents(byteStream([wire])))
    expect(out).toBe('event: response.completed\ndata: ' + COMPLETED_JSON + '\n\n')
  })

  it('keeps a trailing partial that never continues byte-identical', async () => {
    const wire = 'event: response.completed\ndata: ' + COMPLETED_JSON.slice(0, 700) + '\n\n'
    expect(await drain(reassembleSplitSseEvents(byteStream([wire])))).toBe(wire)
  })

  it('flushes the held partial verbatim when the next event parses on its own', async () => {
    const wire = 'event: response.completed\ndata: ' + COMPLETED_JSON.slice(0, 700) + '\n\n'
      + 'data: {"delta":"hi"}\n\n'
    expect(await drain(reassembleSplitSseEvents(byteStream([wire])))).toBe(wire)
  })

  it('passes comment-only and empty-data frames through without joining them', async () => {
    const cut = 400
    const wire = ': keep-alive\n\n'
      + 'event: response.completed\ndata: ' + COMPLETED_JSON.slice(0, cut) + '\n\n'
      + ': keep-alive\n\n'
      + 'data: ' + COMPLETED_JSON.slice(cut) + '\n\n'
    const out = await drain(reassembleSplitSseEvents(byteStream([wire])))
    expect(out).toBe(': keep-alive\n\n: keep-alive\n\nevent: response.completed\ndata: ' + COMPLETED_JSON + '\n\n')
  })
})

describe('reassembleSplitSseEvents against pi-ai openai-responses api', () => {
  const original = globalThis.fetch
  afterEach(() => { globalThis.fetch = original })

  it('allows pi-ai to successfully consume a relay-split stream', async () => {
    const api = openAIResponsesApi()
    const cut = COMPLETED_JSON.indexOf('xxx') + 450
    const wire = 'event: response.completed\ndata: ' + COMPLETED_JSON.slice(0, cut) + '\n\n'
      + 'data: ' + COMPLETED_JSON.slice(cut) + '\n\n'

    // 1. Negative control: without reassembly, pi-ai yields an error stopReason
    globalThis.fetch = async () => new Response(byteStream([wire]), {
      status: 200,
      headers: { 'content-type': 'text/event-stream; charset=utf-8' },
    })

    const failingEvents: unknown[] = []
    for await (const event of api.stream(MOCK_MODEL, MOCK_CONTEXT, { apiKey: 'test-key' })) {
      failingEvents.push(event)
    }
    const lastFailing = failingEvents[failingEvents.length - 1] as { type: string; reason?: string }
    expect(lastFailing.type).toBe('error')

    // 2. Positive control: with reassembly installed, pi-ai successfully finishes with 'stop'
    const restore = installSseReassembly(() => new Set(['https://relay.test']))
    const successEvents: unknown[] = []
    for await (const event of api.stream(MOCK_MODEL, MOCK_CONTEXT, { apiKey: 'test-key' })) {
      successEvents.push(event)
    }
    restore()

    const lastSuccess = successEvents[successEvents.length - 1] as { type: string; reason?: string; error?: unknown }
    if (lastSuccess.type !== 'done') {
      console.log('UNEXPECTED SUCCESS ERROR:', JSON.stringify(lastSuccess))
    }
    expect(lastSuccess.type).toBe('done')
    expect(lastSuccess.reason).toBe('stop')
  })
})

describe('reassemblyOrigins', () => {
  it('collects the origins of routes with an explicit baseURL only', () => {
    const origins = reassemblyOrigins(new Map([
      ['relay', { baseURL: 'https://free.empero.org/v1' }],
      ['plain-http', { baseURL: 'http://47.77.235.179:8317/v1' }],
      ['catalog-route', {}],
      ['malformed', { baseURL: 'not a url' }],
    ]))
    expect([...origins].sort()).toEqual(['http://47.77.235.179:8317', 'https://free.empero.org'])
  })
})

describe('installSseReassembly', () => {
  const original = globalThis.fetch
  afterEach(() => { globalThis.fetch = original })

  it('leaves responses from other origins and non-SSE responses untouched', async () => {
    const untouched = new Response('{"ok":true}', { headers: { 'content-type': 'application/json' } })
    const sseOther = new Response('data: {}\n\n', { headers: { 'content-type': 'text/event-stream' } })
    const calls: string[] = []
    const fake: typeof fetch = async (input) => {
      const urlString = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
      calls.push(urlString)
      return urlString === 'https://relay.test/v1/a' ? untouched : sseOther
    }
    globalThis.fetch = fake
    const restore = installSseReassembly(() => new Set(['https://relay.test']))

    expect(await globalThis.fetch('https://relay.test/v1/a')).toBe(untouched)
    expect(await globalThis.fetch('https://elsewhere.test/v1')).toBe(sseOther)
    expect(calls).toEqual(['https://relay.test/v1/a', 'https://elsewhere.test/v1'])

    restore()
    expect(globalThis.fetch).toBe(fake)
  })

  it('rewrites the body of event-stream responses from hardened origins', async () => {
    const cut = COMPLETED_JSON.indexOf('xxx') + 450
    const wire = 'event: response.completed\ndata: ' + COMPLETED_JSON.slice(0, cut) + '\n\n'
      + 'data: ' + COMPLETED_JSON.slice(cut) + '\n\n'
    const fake: typeof fetch = async () => new Response(byteStream([wire]), {
      status: 200,
      headers: { 'content-type': 'text/event-stream; charset=utf-8', 'x-request-id': 'r1' },
    })
    globalThis.fetch = fake
    const restore = installSseReassembly(() => new Set(['https://relay.test']))

    const response = await globalThis.fetch('https://relay.test/v1/responses')
    expect(response.status).toBe(200)
    expect(response.headers.get('x-request-id')).toBe('r1')
    expect(await drain(response.body!)).toBe('event: response.completed\ndata: ' + COMPLETED_JSON + '\n\n')

    restore()
    expect(globalThis.fetch).toBe(fake)
  })

  it('supports URL, Request, and unparseable input', async () => {
    globalThis.fetch = async (input) => {
      const urlString = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
      if (urlString === '/relative') return new Response(null, { headers: { 'content-type': 'text/event-stream' } })
      return new Response('data: {}\n\n', { headers: { 'content-type': 'text/event-stream' } })
    }
    const restore = installSseReassembly(() => new Set(['https://relay.test']))

    expect(await globalThis.fetch(new URL('https://relay.test/v1'))).toBeInstanceOf(Response)
    expect(await globalThis.fetch(new Request('https://relay.test/v1'))).toBeInstanceOf(Response)
    const rel = await globalThis.fetch('/relative')
    expect(rel.body).toBeNull()

    // Foreign wrapper installed on top: restore does not overwrite it
    const foreignWrapper: typeof fetch = async () => new Response()
    globalThis.fetch = foreignWrapper
    restore()
    expect(globalThis.fetch).toBe(foreignWrapper)
  })
})
