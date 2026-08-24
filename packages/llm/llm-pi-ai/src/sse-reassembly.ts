/**
 * Transport reassembly for OpenAI-style SSE feeds that a relay re-segments
 * mid-payload: one logical event arrives as several consecutive events, each
 * re-prefixed with its own `data:` field and its own blank-line terminator.
 * Spec-conformant decoders (the openai SDK pi-ai rides on) reject the pieces
 * with `Unterminated string in JSON`, so this module re-joins them before the
 * SDK sees the stream.
 *
 * The reassembly is contract-preserving for conformant feeds: frames whose
 * payload parses as JSON, comment frames, and `[DONE]` frames pass through
 * byte-identical. Only a payload that fails to parse as an input that ran out
 * mid-token is joined with the following frame's payload, and a held partial
 * that never completes is flushed verbatim so the original decode failure
 * surfaces unchanged.
 *
 * @module dsh-llm-pi-ai/sse-reassembly
 */

const CR = 0x0d
const LF = 0x0a

/** One parsed SSE frame's event name and joined `data:` payload. */
interface ParsedFrame {
  event: string | null
  data: string
}

function concatBytes(left: ArrayLike<number>, right: ArrayLike<number>): Uint8Array {
  const out = new Uint8Array(left.length + right.length)
  out.set(left)
  out.set(right, left.length)
  return out
}

/**
 * Find the first blank-line frame terminator (`\n\n`, `\r\n\r\n`, or `\r\r`).
 * @param bytes - the buffered wire bytes.
 * @returns the index and length of the terminator, or `undefined` while the
 *   buffer holds no complete frame (a partial terminator at the buffer end
 *   deliberately does not match; more bytes may complete it).
 */
function findSeparator(bytes: Uint8Array): { index: number; length: number } | undefined {
  for (let i = 0; i < bytes.length; i++) {
    if (bytes[i] === LF && i + 1 < bytes.length && bytes[i + 1] === LF) return { index: i, length: 2 }
    if (bytes[i] === CR) {
      if (i + 3 < bytes.length && bytes[i + 1] === LF && bytes[i + 2] === CR && bytes[i + 3] === LF) {
        return { index: i, length: 4 }
      }
      if (i + 1 < bytes.length && bytes[i + 1] === CR) return { index: i, length: 2 }
    }
  }
  return undefined
}

/**
 * Read one complete frame's `event` name and `data` payload the same way the
 * openai SDK does: lines split on any ending, `data:` values joined with `\n`,
 * one optional leading space stripped per value.
 * @param frame - the frame's bytes including its blank-line terminator.
 * @returns the parsed fields.
 */
function parseFrame(frame: Uint8Array): ParsedFrame {
  const text = new TextDecoder().decode(frame)
  let event: string | null = null
  const data: string[] = []
  for (const line of text.split(/\r\n|\r|\n/)) {
    if (line.startsWith('data:')) {
      const value = line.slice('data:'.length)
      data.push(value.startsWith(' ') ? value.slice(1) : value)
    } else if (line.startsWith('event:')) {
      const value = line.slice('event:'.length)
      event = value.startsWith(' ') ? value.slice(1) : value
    }
  }
  return { event, data: data.join('\n') }
}

function parsesAsJson(text: string): boolean {
  try {
    JSON.parse(text)
    return true
  } catch {
    return false
  }
}

/**
 * Whether a payload looks like JSON whose input ran out mid-token — the exact
 * failure a re-segmenting relay produces. V8 reports the exhaustion position
 * as the input length for an unterminated string, and `Unexpected end of JSON
 * input` for structural exhaustion; anything else is corruption this module
 * must not paper over.
 * @param text - the frame payload.
 * @returns `true` only for end-of-input truncation.
 */
function truncatedJson(text: string): boolean {
  try {
    JSON.parse(text)
    return false
  } catch (error) {
    const message = (error as Error).message
    if (message === 'Unexpected end of JSON input') return true
    const position = /Unterminated string in JSON at position (\d+)/.exec(message)
    return position !== null && Number(position[1]) === text.length
  }
}

/** A partial payload held while waiting for its continuation frames. */
interface HeldFrame {
  event: string | null
  data: string
  raw: Uint8Array
}

class SseReassembler {
  private pending: Uint8Array = new Uint8Array(0)
  private held: HeldFrame | undefined

  /**
   * Absorb one read chunk and return the frames now safe to forward.
   * @param chunk - wire bytes as received.
   * @returns frames to emit, verbatim or synthesized; empty while everything
   *   buffered is still partial.
   */
  push(chunk: Uint8Array): Uint8Array[] {
    const out: Uint8Array[] = []
    this.pending = concatBytes(this.pending, chunk)
    for (;;) {
      const separator = findSeparator(this.pending)
      if (separator === undefined) break
      const frame = this.pending.slice(0, separator.index + separator.length)
      this.pending = this.pending.slice(separator.index + separator.length)
      const emitted = this.frame(frame)
      if (emitted !== undefined) out.push(emitted)
    }
    return out
  }

  /** At stream end, forward any held partial and unterminated tail verbatim. */
  flush(): Uint8Array[] {
    const out: Uint8Array[] = []
    if (this.held !== undefined) {
      out.push(this.held.raw)
      this.held = undefined
    }
    if (this.pending.length > 0) {
      out.push(this.pending)
      this.pending = new Uint8Array(0)
    }
    return out
  }

  /**
   * Decide the output for one complete frame.
   * @param frame - the frame's bytes including its terminator.
   * @returns bytes to emit — the frame verbatim, a held prefix concatenated
   *   onto it, or a synthesized reassembled frame — or `undefined` while the
   *   payload is held awaiting its continuation.
   */
  private frame(frame: Uint8Array): Uint8Array | undefined {
    const parsed = parseFrame(frame)
    // Comment frames and event-name-only frames carry no payload to join.
    if (parsed.data.length === 0) return frame
    // `[DONE]` is the stream sentinel, never a continuation.
    if (parsed.data.startsWith('[DONE]')) return this.flushHeld(frame)
    if (parsesAsJson(parsed.data)) return this.flushHeld(frame)
    if (this.held !== undefined) {
      const joined = this.held.data + parsed.data
      if (parsesAsJson(joined)) {
        const event = this.held.event
        this.held = undefined
        return new TextEncoder().encode(
          `${event === null ? '' : `event: ${event}\n`}data: ${joined}\n\n`,
        )
      }
      // Still unterminated: keep accumulating. A relay may re-segment one
      // payload into any number of frames, so the held partial grows until a
      // continuation completes it.
      if (truncatedJson(joined)) {
        this.held = { event: this.held.event, data: joined, raw: concatBytes(this.held.raw, frame) }
        return undefined
      }
      return this.flushHeld(frame)
    }
    if (truncatedJson(parsed.data)) {
      this.held = { event: parsed.event, data: parsed.data, raw: frame }
      return undefined
    }
    // Corruption that is not end-of-input truncation: forward unchanged and
    // let the conformant decoder fail exactly as it would have.
    return frame
  }

  /**
   * Emit a held partial verbatim ahead of a frame that terminates it as a
   * peer (`[DONE]`, independently parseable, or non-truncating corruption).
   * @param frame - the frame to follow the flushed partial.
   * @returns both frames' bytes contiguous.
   */
  private flushHeld(frame: Uint8Array): Uint8Array {
    if (this.held === undefined) return frame
    const raw = this.held.raw
    this.held = undefined
    return concatBytes(raw, frame)
  }
}

/**
 * Re-join SSE events a relay split mid-payload. Byte-identical for conformant
 * feeds; see the module comment for the exact conditions under which frames
 * are synthesized.
 * @param body - the response body as fetched.
 * @returns a body emitting the reassembled feed.
 */
export function reassembleSplitSseEvents(body: ReadableStream<Uint8Array>): ReadableStream<Uint8Array> {
  const reassembler = new SseReassembler()
  return body.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      for (const out of reassembler.push(chunk)) controller.enqueue(out)
    },
    flush(controller) {
      for (const out of reassembler.flush()) controller.enqueue(out)
    },
  }))
}

/**
 * Collect the origins of routes this deployment pointed at its own endpoints.
 * Only those get reassembly: an installed catalog route keeps pi-ai's own
 * transport untouched, and a route without a `baseURL` is one of those.
 * @param profiles - the currently resolved provider profiles.
 * @returns the origins to harden. An unparseable `baseURL` is skipped rather
 *   than thrown so one bad route cannot uninstall reassembly for the rest.
 */
export function reassemblyOrigins(profiles: ReadonlyMap<string, { baseURL?: string }>): ReadonlySet<string> {
  const origins = new Set<string>()
  for (const profile of profiles.values()) {
    if (profile.baseURL === undefined) continue
    try {
      origins.add(new URL(profile.baseURL).origin)
    } catch {
      // The route's own requests fail loudly on this URL already.
    }
  }
  return origins
}

/**
 * The request URL, or `undefined` for an input whose URL cannot be parsed in
 * isolation (a relative-URL `Request`, which global fetch rejects anyway).
 * @param input - the fetch input.
 * @returns the parsed URL.
 */
function requestUrl(input: RequestInfo | URL): URL | undefined {
  try {
    return new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url)
  } catch {
    return undefined
  }
}

/**
 * Wrap global fetch so `text/event-stream` responses from the given origins
 * pass through {@link reassembleSplitSseEvents}. Every other response — other
 * origins, other content types, empty bodies — is returned as fetched.
 * @param origins - the live origin set, re-read per request so route changes
 *   reach it without reinstalling the wrapper.
 * @returns the restore function putting the previous fetch back, guarded so a
 *   foreign later wrapper is never clobbered.
 */
export function installSseReassembly(origins: () => ReadonlySet<string>): () => void {
  const previous = globalThis.fetch
  const hardened: typeof fetch = async (input, init) => {
    const response = await previous(input, init)
    const url = requestUrl(input)
    if (url === undefined || response.body === null) return response
    if (!origins().has(url.origin)) return response
    const contentType = response.headers.get('content-type') ?? ''
    if (!contentType.includes('text/event-stream')) return response
    return new Response(reassembleSplitSseEvents(response.body), {
      status: response.status,
      statusText: response.statusText,
      headers: response.headers,
    })
  }
  globalThis.fetch = hardened
  return () => {
    if (globalThis.fetch === hardened) globalThis.fetch = previous
  }
}
