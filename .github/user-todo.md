# User Todo (Priority Order)

1. **Research opencli** — Design site-specific CLI subcommands for WebKitAgent

## Completed
- Chat attachment support (images, docs) — PhotosPicker, DocumentPicker, attachment preview
- Speech input — SFSpeechRecognizer, mic button in InputBar  
- WebKitAgent integration — web_agent tool working on device
- Reverse MCP bridge working: device → WebSocket → bridge → curl
- All 4 MCP tools work on device: app_agent, send_message, get_messages, get_status
- Full chat flow verified on device (send message → GPT-4.1 → response displayed)
- Fixed ATS: added NSAllowsLocalNetworking for ws:// connections
- 41 tests pass
