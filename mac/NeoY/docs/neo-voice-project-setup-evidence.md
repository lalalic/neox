# Neo Voice Project setup result

Date: 2026-10-18 (fresh Browser Workspace verification)
Root cause: not applicable; this is feature work.

## Result

The `Neo Voice` ChatGPT Project and persistent thread binding were **not established**. No project-wide instructions were saved, and no Project ID or thread ID was persisted. The authenticated ChatGPT account's live Projects section showed `unresolved`, `fund`, `maggie`, `sammy`, and `Exstream`; it did not show `Neo Voice`.

## Fresh platform evidence

- `uvx browser-workspace platform profile chatgpt` lists `project-bootstrap`, `project-instructions`, `persistent-thread`, and `lifecycle-control-transfer` capabilities.
- Running the supported `chatgpt project-setup` action for `Neo Voice` failed in Browser Workspace's `_ensure_project` step with `RuntimeError: ChatGPT project name field not found`. The live Projects sidebar exposed an enabled **Add new project** control, but after the action and a same-session inspection there was no project-name field or creation dialog. No project-creation receipt or identifiers were returned.
- A fresh `chatgpt mcp-app` status check for app `neo` returned `connected: false`, `permissions: false`, and `refresh_tools: true`. Because the app is disconnected, the authenticated `voice.complete` tool's availability could not be verified.
- NeoY runtime inspection found the existing `Runtime/src/core/tools/xchat.mjs` facade accepts stable `project_id` and `thread_id` on each turn, but has no persisted Neo Voice binding. No Browser Workspace tab ID, URL, selector, or other browser identity was added to product state.

## Project-wide instructions prepared, not applied

The setup attempt used this instruction text, but ChatGPT did not save it because Project creation stopped before a Project settings page was available:

> You are the ChatGPT conversational endpoint for Neo Voice. Every inbound spoken user turn is submitted into this project's persistently bound ChatGPT thread by Browser Workspace; continue that bound thread and preserve its conversation context. A submission acknowledgement only confirms the turn was accepted and is never proof that a reply was delivered. For each spoken turn, deliver the final reply by calling the authenticated Neo MCP voice reply capability exposed by the connected `neo` MCP app (`voice.complete`), using the active voice session, correlation ID, sequence, and final marker required by that tool. Never use ChatGPT's changing reply DOM, page text, or browser UI as the delivery channel or claim audible delivery from observing it. If the voice tool is unavailable or reports failure, state that delivery failed; do not claim success. Typed turns remain text-only unless the user explicitly asks for spoken delivery.

## Architecture Lens and implementation notes

- Native necessity: Project setup and ChatGPT thread routing do not require NeoY's process, TCC, or native privileges; Browser Workspace owns browser operations.
- Existing owner: Browser Workspace owns ChatGPT UI mechanics. NeoY Core's existing `chatgpt` facade in `xchat.mjs` owns turn/thread lifecycle transfer. No separate binding MCP surface was added.
- Intent boundary and surface growth: the existing `chatgpt` facade is the supported control-transfer surface; no DOM or low-level browser primitive was added to the public MCP contract.
- Business versus platform identity: a stable Project/thread binding could only be persisted after receiving real Project and thread IDs. None were returned, so no binding was fabricated or saved. Browser tab IDs, URLs, selectors, and workspace identities remain platform mechanics.
- Lifecycle semantics: instructions distinguish ChatGPT submission acknowledgement from completed voice delivery and require the authenticated `voice.complete` capability. Instructions cannot guarantee a model tool call; the disconnected MCP app prevents verification of this delivery path.

## Required user action to unblock

1. In ChatGPT, create the `Neo Voice` Project through the normal Projects UI (the Browser Workspace project setup action currently cannot reach the project-name field).
2. Connect or re-authorize the `neo` MCP app in ChatGPT Settings → Plugins, refresh its tools, and verify the authenticated `voice.complete` capability is exposed.
3. Re-run the Browser Workspace setup flow to apply the instructions and create the intended persistent thread. Once the platform returns real Project and thread IDs, persist those stable business IDs in the existing runtime owner and verify a new turn is submitted to that binding.

No successful Project configuration or binding is claimed by this result.

## 2026-10-20 follow-up

- Retried the supported Browser Workspace `chatgpt project-setup` action in a
  caller-owned session. It again stopped at `ChatGPT project name field not
  found`. A fresh accessibility snapshot showed the Projects section, existing
  project controls, and **Add new project**; invoking that control through the
  session did not open a creation dialog. No Project or thread was created and
  no IDs were returned.
- Refreshed tools for the installed `neo` ChatGPT app, then re-read its status.
  It remains `connected: false`, `permissions: false`; authenticated `voice.reply`
  invocation from ChatGPT is therefore unavailable.
- NeoY cluster discovery still lists `work`, but `cluster status work` returned
  `Could not connect to the server`. Per the Worknode access rule, no direct SSH
  or alternate access path was used. The `neo-livekit-smoke` container state,
  LiveKit credentials, and room participants could not be verified or touched.
- Added `testNoMicMCPFacadeRoundTripSubmitsThenDeliversCorrelatedSegments`, which
  exercises the registered `voice.session` MCP facade: no-mic text injection
  returns `submitted`, two correlated `voice.reply` segments reach the fake
  synthesizer in order, and only the final segment returns a delivered receipt.
  This is an in-process boundary injection test. It is not ChatGPT or LiveKit
  E2E and does not represent real audio playback.
- Focused VoiceSession suite: **18 tests, 0 failures** on 2026-10-20. No speech,
  TTS/room media, playback latency, or ChatGPT delivery latency was measured.

The required LiveKit pipeline and full no-microphone ChatGPT→LiveKit E2E remain
unimplemented/unverified; this follow-up must not be treated as acceptance of
those reviewer findings.
