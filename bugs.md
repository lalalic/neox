# Site Adapter Bugs

Testing date: 2026-03-31
Method: On-device chat testing via MCP + code review + Swift unit tests (167 tests pass)
Updated: 2026-04-09

## Fixed

- **Bug #1** (wechat/send non-functional): Fixed — args now injected via `__adapterArgs`
- **Bug #2** (wechat/contacts limit hardcoded): Fixed — uses `__adapterArgs.limit`
- **Bug #3** (adapter args not passed to JS): Fixed — `executeBrowserAdapter()` injects `const __adapterArgs = {...}` before script
- **Bug #4** (wechat/status no preNavigate): Fixed — added `preNavigate: https://wx.qq.com`
- **Bug #5** (formatOutput key sorting): Low/cosmetic, not blocking

## Open

### Bug #6: Chat agent gets stuck in "working" state

**File:** Likely in ChatViewModel or agent pipeline
**Severity:** Medium — blocks testing after ~5 messages

After accumulating several messages with tool results (especially large HN story lists), the chat agent gets stuck in "working" state (`agentRunning: false` but `chatState: working`). Possibly caused by context window overflow or LLM timeout.

**Not an adapter bug** — this is a chat pipeline issue.

### Bug #7: AccessibilityScanner compile error — FIXED

Already uses `frame.size.width` / `frame.size.height`.
