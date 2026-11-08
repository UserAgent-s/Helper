# UserAgent057 — Project Instructions

## No code comments

Do not write comments in any source file (`//`, `///`, `/* */`) — not for
"what" and not for "why". This applies to Swift, Python, and every other
language in this repo. Reasoning, rationale, and non-obvious constraints go
in `docs/implementation-status.md` (per stage) and ADRs under `docs/adr/`,
not inline — those are the durable record. Token economy is the reason: this
codebase is grown by long automated Claude Code runs, and inline comment
prose is re-read (and re-billed) on every future pass for no benefit once
the same rationale already lives in `docs/`.

This overrides any impulse to document a tricky concurrency workaround or
architectural decision inline — write the workaround in code, and put one
line about it in that stage's `docs/implementation-status.md` entry instead.

## Testing Philosophy

MCP lets Claude drive tools; it does not replace ordinary automated tests.
In priority order:

1. **Unit tests** — mode transitions (passive/answers/recording); full
   audio/STT/network/write teardown in passive; context accumulation up to a
   question; handling of the `⟦WAIT_FOR_QUESTION⟧` sentinel; dedup of an
   automatic answer racing a manual one; context clears only after a
   completed answer, never mid-stream; internal markers are filtered before
   reaching the UI.
2. **Integration tests with a fake Realtime transport** — replay a
   pre-recorded event sequence; assert the first text delta arrives before
   `response.done`; assert the "Answer now" button produces exactly one
   `response.create`; assert recording mode never calls OpenAI; assert
   answers mode never starts Whisper.
3. **Audio fixtures** — Russian and English questions; a long task
   explanation before the actual question; pauses, background noise,
   interruptions; several context turns; a question automation missed,
   followed by a manual trigger.
4. **XCUITest** — mode switching; the menu bar; the answer overlay
   appearing; streaming text updates; the "Answer now" button; the global
   hotkey; behavior when permissions are missing.
5. **Real API tests — manual or a separate opt-in target only**: audio →
   first text delta; "Answer now" → first text delta; p50/p95 latency;
   WebSocket reconnection; rate-limit behavior. Never run real, paid OpenAI
   tests on every commit — slow, costly, and flaky.

Also:

- Use `xcodebuild`/`XCTest` directly rather than wrapping everything in MCP.
- Playwright is not needed for this native macOS app — it would only matter
  for a future web panel or a PHP token broker.
- Provide one `make verify-fast` (build + unit tests + static checks) and a
  separate `make verify-real` that requires an explicit API key and talks to
  the real Realtime API.
- Profile with Instruments: Time Profiler, Allocations, Energy Log.
- Verify real system-audio capture and ScreenCaptureKit permission prompts
  on a physical Apple-silicon Mac — cloud CI cannot fully reproduce this.
- Pin Swift package versions and the XcodeGen version.
- Keep `.mcp.json` in the project, but never put API keys in it.
- Do not install redundant Filesystem/Shell/Git/SQLite MCP servers — Claude
  Code already handles files, the terminal, and git.
- Never grant an MCP server automatic permission for destructive commands.
- Never connect an unknown or unvetted MCP server to the meeting-recordings
  store — audio and transcripts may contain confidential information.
