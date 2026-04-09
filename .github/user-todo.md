# User Todo (Priority Order)

(No pending items — all tasks complete)

## Completed
- Research opencli / Site Adapters — 18 bundled adapters: HackerNews (3), WeChat (4), Xiaohongshu (4), GitHub (2), Reddit (3), ProductHunt (1), Convertio (1). Added `extract` pipeline step for nested JSON. 238 tests pass.
- Plan Management — PlanStore, PlanExecutor (BGTask), PlanManagerView, PlanHistoryView all in copilot-ios. Fixed corrupted AgentCoordinator.swift. Removed duplicate neox files.
- Context awareness — environment_context section with device/battery/network/storage/time
- CookieRefreshManager — periodic background cookie refresh
- Bug #6 fix — chat stuck in working state
- Bug cleanup — all bugs.md entries marked fixed
- Chat attachment support (images, docs) — PhotosPicker, DocumentPicker, attachment preview
- Speech input — SFSpeechRecognizer, mic button in InputBar  
- WebKitAgent integration — web_agent tool working on device
- Reverse MCP bridge working: device → WebSocket → bridge → curl
- All 4 MCP tools work on device: app_agent, send_message, get_messages, get_status
- Full chat flow verified on device (send message → GPT-4.1 → response displayed)
- Fixed ATS: added NSAllowsLocalNetworking for ws:// connections
- 41 tests pass (neox) + 238 tests pass (WebKitAgent)
