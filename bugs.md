# Site Adapter Bugs

Testing date: 2026-03-31
Method: On-device chat testing via MCP + code review + Swift unit tests (167 tests pass)

## Test Results Summary

| Adapter | Status | Notes |
|---------|--------|-------|
| hackernews/top | ✅ PASS | Returns 10 stories with titles, URLs, scores |
| hackernews/new | ⚠️ PARTIAL | Pipeline code is correct (different API endpoint), but LLM sometimes routes to "top" instead |
| hackernews/best | ⚠️ UNTESTED (chat stuck) | Pipeline code looks correct |
| site list | ✅ PASS | All 7 adapters listed correctly |
| wechat/login | 🐛 BUG | See Bug #3 |
| wechat/status | 🐛 BUG | See Bug #3 |
| wechat/contacts | 🐛 BUG | See Bug #4, #3 |
| wechat/send | 🐛 BUG | See Bug #1, #3 |

## Bug #1: wechat/send adapter is non-functional (CRITICAL)

**File:** `WebKitAgent/Sources/Adapters/AdapterRegistry.swift` lines 265-290
**Severity:** Critical

The script just returns `{status: "ready", message: "Use evaluate command to send..."}`. It never actually sends a message. The `to` and `message` args are defined in the adapter YAML but never used in the JavaScript.

**Root cause:** Browser adapter args are not injected into JavaScript. See Bug #3.

## Bug #2: wechat/contacts hardcodes limit to 50

**File:** `WebKitAgent/Sources/Adapters/AdapterRegistry.swift` line 245
**Severity:** Minor

The script uses `.slice(0, 50)` instead of using the `limit` parameter from adapter args.

**Root cause:** Same as Bug #3 — args aren't injected into the script context.

## Bug #3: Browser adapter args NOT passed to JavaScript (CRITICAL)

**File:** `WebKitAgent/Sources/WebAgentToolProvider.swift` → `executeBrowserAdapter()`
**Severity:** Critical — affects ALL browser-based adapters (wechat/*)

The `executeBrowserAdapter()` method receives `args: [String: String]` but never injects them into the JavaScript execution context. The script runs as a static string via `evaluateJSPublic()` with no variable substitution.

**Expected:** Args like `to`, `message`, `limit` should be injected as JS variables before script execution.
**Actual:** Scripts run with no access to adapter args.

```swift
// Current code — args are received but unused:
private func executeBrowserAdapter(_ adapter: YAMLAdapter, args: [String: String]) async throws -> String {
    if let url = adapter.preNavigate {
        _ = try await manager.navigate(to: url)
    }
    if let wait = adapter.waitSeconds, wait > 0 {
        try await Task.sleep(for: .seconds(wait))
    }
    if let script = adapter.script {
        let resultJSON = try await manager.evaluateJSPublic(script) // ← args NOT injected
        ...
    }
}
```

**Fix:** Prepend `const args = {...};` to the script before evaluation.

## Bug #4: wechat/status has no preNavigate URL

**File:** `WebKitAgent/Sources/Adapters/AdapterRegistry.swift` lines 207-225
**Severity:** Medium

The `wechat/status` adapter has no `preNavigate` field. If the browser isn't already on wx.qq.com, the script will fail because it tries to access `angular.element()` which won't exist on another page.

**Fix:** Add `preNavigate: https://wx.qq.com` to the wechat/status adapter definition.

## Bug #5: formatOutput sorts dict keys alphabetically (cosmetic)

**File:** `WebKitAgent/Sources/Adapters/PipelineEngine.swift` → `formatOutput()`
**Severity:** Low/cosmetic

The output format sorts dictionary keys alphabetically: `author | rank | score | title | url`. This makes the most important field (rank) appear in the middle. Expected order: `rank | title | url | score | author`.

**Fix:** Use ordered output or a priority-based sort for known fields.

## Bug #6: Chat agent gets stuck in "working" state

**File:** Likely in ChatViewModel or agent pipeline
**Severity:** Medium — blocks testing after ~5 messages

After accumulating several messages with tool results (especially large HN story lists), the chat agent gets stuck in "working" state (`agentRunning: false` but `chatState: working`). Possibly caused by context window overflow or LLM timeout.

**Not an adapter bug** — this is a chat pipeline issue.

## Bug #7: AccessibilityScanner compile error (unrelated)

**File:** `AppAgent/Sources/AccessibilityScanner.swift` line 43
**Severity:** Medium — blocks building AppAgent tests on macOS

```swift
let w = Int(frame.width), h = Int(frame.height)
// Error: value of type 'CGRect' has no member 'width'/'height'
```

**Fix:** Use `frame.size.width` and `frame.size.height` instead.

## Recommended Fix Priority

1. **Bug #3** — Fix args injection in executeBrowserAdapter (unblocks all wechat adapters)
2. **Bug #1** — Rewrite wechat/send script to actually send messages using injected args
3. **Bug #4** — Add preNavigate to wechat/status
4. **Bug #2** — Use injected limit arg in wechat/contacts
5. **Bug #5** — Improve formatOutput field ordering
6. **Bug #7** — Fix CGRect width/height for macOS build
7. **Bug #6** — Investigate chat pipeline stuck state (separate task)
8. **Bug #8** — WeChat QR login: scanned barcode shows QR code but not logged in (reported 2026-04-03)
