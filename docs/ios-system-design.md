# ios_system Integration Design

## Goal

Replace most file/shell tools with a single `run_in_terminal` tool backed by [holzschu/ios_system](https://github.com/holzschu/ios_system). Keep only `read_file` and `write_file` as dedicated tools.

## Why

- LLMs already know bash — zero prompt engineering needed
- One tool (`run_in_terminal`) replaces `list_files`, `create_directory`, `ffmpeg`, `ffprobe`, and more
- Agent can chain commands naturally (`&&`, `|`, `>`)
- Reduces tool count → more context budget for actual work

## Current Tool Inventory

```
FileToolProvider:     read_file, write_file, list_files, create_directory, create_project
MemoryToolProvider:   memory_read, memory_append, memory_write_section, memory_log_session, memory_list, memory_search, memory_delete, memory_get_yesterday
FFmpegToolProvider:   ffmpeg, ffprobe
SubAgentToolProvider: run_sub_agent
ContextToolProvider:  get_context
WebAgentToolProvider: web_agent
ChatViewModel:        send_response, ask_questions, manage_todo_list, create_plan, view, convert_to_markdown, stripe_checkout, start_coding_task
Registered:           speak, listen, notify, take_photo, copy_to_clipboard
```

## Proposed Tool Inventory (After)

### Keep as tools (structured I/O needed)
- `read_file` — returns file content with encoding handling
- `write_file` — atomic write with directory creation
- `run_in_terminal` — **NEW**, backed by ios_system

### Remove (replaced by run_in_terminal)
- `list_files` → `ls -la`
- `create_directory` → `mkdir -p`
- `ffmpeg` → `ffmpeg` (ios_system includes it via framework)
- `ffprobe` → `ffprobe` (same)

### Keep unchanged (iOS-specific, no bash equivalent)
- `send_response`, `ask_questions`, `manage_todo_list`, `create_plan`
- `web_agent`, `run_sub_agent`, `get_context`
- `speak`, `listen`, `notify`, `take_photo`, `copy_to_clipboard`
- `view`, `convert_to_markdown`
- `stripe_checkout`, `start_coding_task`
- `create_project` — template scaffolding (keep or move to bash script)
- All `memory_*` tools — keep for now (semantic operations on .neo/ files)

## run_in_terminal Tool Design

```json
{
  "name": "run_in_terminal",
  "description": "Execute a shell command in the on-device terminal. Supports standard Unix commands: ls, cat, grep, find, mkdir, cp, mv, rm, sed, awk, curl, tar, echo, wc, sort, head, tail, etc. Commands run sandboxed in the workspace directory. Use && to chain commands. Use | for pipes.",
  "parameters": {
    "command": "string (required) — the shell command to execute",
    "explanation": "string (optional) — brief description of what the command does"
  }
}
```

### Implementation

```
┌─────────────────────────────────────────┐
│ run_in_terminal handler                 │
│                                         │
│ 1. Receive command string               │
│ 2. Set working directory to workspace   │
│ 3. Capture stdout + stderr via pipes    │
│ 4. Call ios_system(command)             │
│ 5. Collect output                       │
│ 6. Truncate if > 60KB                   │
│ 7. Return output string + exit code     │
└─────────────────────────────────────────┘
```

### Key ios_system APIs

```swift
// Basic execution
ios_system("ls -la")

// Sandbox to workspace
ios_setMiniRoot(workspaceURL.path)

// Redirect stdout/stderr for capture
thread_stdout = outputPipe
thread_stderr = errorPipe

// Check if command exists
ios_executable("grep")  // returns true/false
```

### New File: TerminalToolProvider.swift

Location: `copilot-ios/CopilotSDK/Sources/TerminalToolProvider.swift`

```
TerminalToolProvider
├── init(workspaceURL: URL)
├── tools: [ToolDefinition]  // just run_in_terminal
└── execute(command: String) async -> (output: String, exitCode: Int32)
```

### Working Directory

- Default: the project's workspace directory (`Documents/workspace/`)
- `ios_setMiniRoot()` prevents escaping the sandbox
- `cd` changes the working directory within the sandbox
- Agent sees paths relative to workspace root

## Integration Points

### 1. Package.swift — Add ios_system dependency

```swift
.package(url: "https://github.com/holzschu/ios_system.git", from: "3.0.0")
```

Target: CopilotSDK (since tool providers live there)

### 2. AgentCoordinator.buildTools() — Wire up

```swift
// Before:
tools.append(contentsOf: fileToolProvider.tools)  // 5 tools
tools.append(contentsOf: ffmpegToolProvider.tools) // 2 tools

// After:
tools.append(contentsOf: fileToolProvider.tools)      // 2 tools (read_file, write_file only)
tools.append(contentsOf: terminalToolProvider.tools)   // 1 tool (run_in_terminal)
// ffmpegToolProvider removed — ffmpeg available via run_in_terminal
```

### 3. FileToolProvider — Slim down

Remove: `listFilesTool`, `createDirectoryTool`, `createProjectTool`
Keep: `readFileTool`, `writeFileTool`

### 4. FFmpegToolProvider — Remove entirely

ffmpeg/ffprobe are already included in ios_system as frameworks. The agent calls them via `run_in_terminal` like it would on desktop:
```
run_in_terminal("ffprobe -v quiet -print_format json -show_format input.mp4")
run_in_terminal("ffmpeg -i input.mp4 -vf scale=720:-1 output.mp4")
```

## Commands Available via ios_system

Out of the box:
- **File:** ls, cp, mv, rm, mkdir, rmdir, touch, ln, cat, stat, du, df, find, chmod, chown
- **Text:** grep, egrep, fgrep, sed, awk, wc, sort, tr, head, tail, less, ed
- **Archive:** tar, gzip, compress
- **Network:** curl, scp, sftp
- **Shell:** echo, env, printenv, pwd, date, uname, whoami

**Not available** (iOS limitation):
- git, bash, zsh, sh (no real shell)
- traceroute, ping (need root — but ping may work via network_ios)
- python, node (separate frameworks, not needed for agent)

## What This Enables

1. **Agent writes scripts**: `echo '#!/bin/sh\necho hello' > script.sh`
2. **Agent processes data**: `cat data.csv | awk -F, '{print $2}' | sort | uniq -c`
3. **Agent searches files**: `grep -r "TODO" --include="*.swift" .`
4. **Agent manages media**: `ffmpeg -i input.mp4 -ss 00:01:00 -t 30 clip.mp4`
5. **Agent checks results**: `ls -la output/ && wc -l result.txt`

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| ios_system commands are BSD (not GNU) | Agent adapts; minor flag differences |
| No real shell (no `if/for/while`) | Keep scripting language plan for complex logic |
| Long-running commands could hang | Add timeout (default 30s) |
| Large output could blow context | Truncate at 60KB, same as desktop Copilot |
| App Store review | ios_system is used in shipped apps (Blink, iVim) |

## Migration Path

1. Add ios_system SPM dependency
2. Create TerminalToolProvider with run_in_terminal
3. Slim FileToolProvider to read_file + write_file
4. Remove FFmpegToolProvider (ffmpeg available via terminal)
5. Update agent system prompt to mention terminal availability
6. Test core commands: ls, cat, grep, curl, ffmpeg
