---
name: terminal-watch
description: Development workflow skill for managing terminals, build processes, and long-running development tasks. Use when starting dev servers, running builds, monitoring processes, get latest error,  or managing multiple terminal sessions for development work.
license: MIT
---

# Terminal Watch - Development Workflow Management

Provides guidance for effective terminal management during development workflows, including build processes, dev servers, and multi-terminal orchestration.

## When to Use This Skill

- Starting and monitoring development servers
- Running build processes that take time
- Managing multiple terminal sessions for different purposes
- Monitoring background processes (watchers, hot-reload servers)
- Coordinating complex build chains with dependencies

## Core Principles

### Named Terminals for Persistent Sessions

Always use **named terminals** via `terminal-tools_sendCommand` for better process management:

```bash
# ✅ Good - Named terminal for dev server
terminal-tools_sendCommand(
  terminalName: "dev-server",
  command: "npm run dev"
)

# ❌ Bad - Generic run_in_terminal loses context
run_in_terminal(command: "npm run dev")
```

### Standard Terminal Names

Use consistent naming for common workflows:

| Terminal Name | Purpose | Examples |
|---------------|---------|----------|
| `dev-server` | Development servers | `npm run dev`, `python manage.py runserver` |
| `build` | Build operations | `./gradlew build`, `npm run build` |
| `test` | Testing | `npm test`, `pytest`, `cargo test` |
| `git` | Version control | Git operations |
| `docker` | Container ops | Docker/podman commands |

### Background vs Foreground Execution

Choose the right execution mode:

**Background** (`captureOutput: false` or not specified):
- Dev servers that need to stay running
- Watch processes (file watchers, hot reload)
- Long-running builds you'll check later

**Foreground** (`captureOutput: true`):
- Quick commands where you need immediate output
- Commands that must complete before next step
- When you need to parse output for decisions

### Watch Mode for Incremental Builds

For development with watch mode (Angular, webpack, etc.), get LATEST build status only:

**Key Pattern**: Redirect output to log file, then search for latest build message AFTER the last rebuild trigger.

```bash
# 1. Start watch mode with output to BOTH console and log file
terminal-tools_sendCommand(
  terminalName: "dev-server",
  command: "cd hydrogen && npm run designer:debug 2>&1 | tee build.log"
)
# Using 'tee' writes to file AND shows in console for visibility

# 2. After making code changes, extract text AFTER last rebuild marker
run_in_terminal(
  command: "tail -n 100 hydrogen/build.log | grep -A 30 'Change detected'",
  explanation: "Extract latest build status after last change detection",
  isBackground: false
)
```

**Understanding Rebuild Markers:**

Watch prebuild markers and success/error patterns (framework-specific):
- **Angular**: 
  - Rebuild marker: `Change detected, rebuilding` or `File change detected`
  - Success: `✔ Compiled successfully` or `Compiled successfully in`
  - Error: `ERROR in` or `✖ Failed to compile`
- **Webpack**: 
  - Rebuild marker: `webpack building...` or `Compiling...`
  - Success: `webpack compiled` or `Build complete`
  - Error: `ERROR` or `Failed to compile`
- **Gradle continuous**: 
  - Rebuild marker: `Change detected, rebuilding` or `Waiting for changes`
  - Success: `BUILD SUCCESSFUL`
  - Error: `BUILD FAILED` or `FAILURE:`

**Search Strategy:**
```bash
# Get text after LAST rebuild marker (most reliable)
tail -n 100 build.log | tac | sed -n '/Change detected/,$p' | tac

# Or get last 100 lines and search for rebuild + result
tail -n 100 build.log | grep -A 30 'Change detected\|Compiling'

# For specific error extraction after last rebuild
tail -n 100 build.log | grep -A 20 'ERROR in'

# If you see:
# "Change detected, rebuilding"
# [end of file or just a few lines]
# → Build STILL IN PROGRESS, wait 2-5 seconds
```

**Pattern Matching for Build Status:**

Common patterns to search for (framework-specific):
- **Angular**: `Compiled successfully`, `ERROR in`, `✔ Compiled successfully`, `✖ Failed to compile`
- **Webpack**: `webpack compiled`, `ERROR`, `WARNING`
- **Gradle continuous**: `BUILD SUCCESSFUL`, `BUILD FAILED`, `FAILURE:`

**Search Strategy:**
```bash
# Get last 100 lines, find build markers, show context
tail -n 100 build.log | grep -E "(Compiled|ERROR|BUILD)" | tail -n 20
AFTER last rebuild marker → Code is good
- ❌ "ERROR" / "Failed to compile" / "BUILD FAILED" AFTER last rebuild marker → Fix needed
- ⏳ Rebuild marker present but NO result after it (or only a few lines) → Still building, wait
- 🔄 "Compiling..." / "Building..." as the last message → In progress, check again in 2-5 seconds

# For specific error extraction
grep -E "ERROR|Failed" build.log | tail -n 20
```

**What to Look For:**
- ✅ "Compiled successfully" / "BUILD SUCCESSFUL" → Code is good
- ❌ "ERROR" / "Failed to compile" / "BUILD FAILED" → Fix needed
- ⏳ "Compiling..." / "Building..." → Wait and check again

## Common Workflows

### Starting Development Servers

```bash
# Start frontend dev server with output to BOTH console and log file
terminal-tools_sendCommand(
  terminalName: "dev-server",
  command: "cd /path/to/hydrogen && npm run designer:debug 2>&1 | tee build.log"
)
# Using 'tee' allows viewing output in console while also logging to file

# Later, check latest build status from log file
run_in_terminal(
  command: "tail -n 100 build.log | grep -E 'Compiled|ERROR' | tail -n 20",
  explanation: "Check latest build status"
)
```

### Multi-Stage Builds

```typescript
// 1. Build dependencies first
terminal-tools_sendCommand(
  terminalName: "build",
  command: "cd /path/to/exstream-common && ./gradlew build",
  captureOutput: true
)

// 2. Then build main project
terminal-tools_sendCommand(
  terminalName: "build",
  command: "cd /path/to/design && ./gradlew clean build"
)
```

### Process Management

```typescript
// List all terminals to see what's running
terminal-tools_listTerminals()

// Cancel a running process (Ctrl+C)
terminal-tools_cancelCommand(terminalName: "dev-server")

// Clean up when done
terminal-tools_deleteTerminal(name: "dev-server")
```

### Monitoring Background Processes

When starting background processes with watch mode, use tee for dual output:

```bash
# Start process with output to BOTH console and log file
terminal-tools_sendCommand(
  terminalName: "dev-server",
  command: "npm run dev 2>&1 | tee dev.log"
)
# Shows output in console for immediate visibility
# Also logs to file for pattern matching and history

# Check latest status from log file
run_in_terminal(
  command: "tail -n 50 dev.log | grep -E 'Compiled|ERROR|Starting'",
  explanation: "Check dev server status"
)

# Stop server
terminal-tools_cancelCommand(terminalName: "dev-server")
```

## Project-Specific Patterns

### Exstream/Hydrogen Development

For the Exstream project with Gradle + Node.js:

```bash
# Full build with dependencies
terminal-tools_sendCommand(
  terminalName: "build",
  command: "cd design && ./gradlew clean build"
)

# Frontend dev server with watch (output to console AND log)
terminal-tools_sendCommand(
  terminalName: "dev-server", 
  command: "cd hydrogen && npm run designer:debug 2>&1 | tee build.log"
)

# Hydrogen build without tests
terminal-tools_sendCommand(
  terminalName: "build",
  command: "cd hydrogen && ./gradlew build -x unitTest -x test -x testSpec"
)
```

**Development Workflow with Watch Mode:**

```typescript
// 1. Start watch mode with dual output (only once at beginning)
terminal-tools_sendCommand(
  terminalName: "dev-server",
  command: "cd hydrogen && npm run designer:debug 2>&1 | tee build.log"
)
// Tell user: "Started dev server with watch mode, output visible in console and logged to build.log"

// 2. Make code changes (edit files)
replace_string_in_file(...)

// 3. Wait briefly for auto-rebuild (2-5 seconds)

// 4. Extract text AFTER the LAST rebuild trigger
run_in_terminal(
  command: "grep -n 'Change detected, rebuilding' hydrogen/build.log | tail -1 | cut -d: -f1 | xargs -I {} tail -n +{} hydrogen/build.log | tail -n 50",
  explanation: "Get output after last rebuild trigger",
  isBackground: false
)

// This gets:
// - Line number of LAST "Change detected, rebuilding" 
// - All text from that line onwards
// - Last 50 lines of that section

// 5. Parse the output:
if (output.contains("Change detected, rebuilding") && output.split("Change detected, rebuilding")[1].trim().length < 50) {
  // ⏳ Pattern found but little/no text after - still building, wait 2-5 seconds and check again
} else if (output.contains("Compiled successfully") || output.contains("✔ Compiled successfully")) {
  // ✅ Good - build completed successfully after last change
} else if (output.contains("ERROR in") || output.contains("Failed to compile") || output.contains("✖ Failed")) {
  // ❌ Build failed - extract error details:
  run_in_terminal(
    command: "grep -A 20 'ERROR in' hydrogen/build.log | tail -n 30",
    explanation: "Get compilation error details"
  )
} else {
  // Still compiling, no final status yet
}

// 6. Simplified approach - just get last 100 lines and check for latest status
run_in_terminal(
  command: "tail -n 100 hydrogen/build.log",
  explanation: "View recent build output"
)
// Then manually check if last "Change detected" has build result after it
```

**Key Pattern for Hydrogen:**
```bash
# Find last rebuild trigger and get everything after it
grep -n 'Change detected, rebuilding' build.log | tail -1 | cut -d: -f1 | xargs -I {} tail -n +{} build.log

# If output shows:
# "Change detected, rebuilding..." with lots of text after → Build completed
# "Change detected, rebuilding..." with nothing/little after → Still building

# Simpler: Get last 100 lines and look for pattern + result
tail -n 100 build.log | grep -A 30 'Change detected'
```

**Alternative: Use grep_search for patterns:**
```typescript
// Search for latest compilation markers
grep_search(
  query: "Compiled successfully|ERROR|Failed",
  isRegexp: true,
  includePattern: "build.log"
)
```

**Viewing Console Messages:**

To see application console output (console.log, System.out.println, etc.) from running dev servers:

```bash
# View recent console output
run_in_terminal(
  command: "tail -n 50 hydrogen/build.log",
  explanation: "View recent console messages"
)

# Follow live output (see new messages as they appear)
run_in_terminal(
  command: "tail -f hydrogen/build.log",
  explanation: "Monitor live console output",
  isBackground: true
)

# Search for specific messages
run_in_terminal(
  command: "grep 'keyword' hydrogen/build.log | tail -n 20",
  explanation: "Find specific console messages"
)

# View all messages from a time period (last 5 minutes)
run_in_terminal(
  command: "tail -n 500 hydrogen/build.log | grep -E 'timestamp_pattern'",
  explanation: "Get messages from specific timeframe"
)
```

### Docker/Podman Operations

```bash
# Build docker image
terminal-tools_sendCommand(
  terminalName: "docker",
  command: "cd design && ./gradlew docker -Plocal-exstream-zip=true"
)
```

## Best Practices

### Before Starting New Work

1. **List existing terminals**: `terminal-tools_listTerminals()` - avoid duplicates
2. **Verify project builds**: Run build in `build` terminal before making changes
3. **Check for running processes**: Don't start multiple dev servers

### During Development

1. **Keep terminals alive**: Don't delete terminals between related operations
2. **Use consistent names**: Same terminal name for same type of work
3. **Monitor periodically**: Check terminal output for errors
4. **Inform users**: Tell users what's running and how to check it
5. **View console messages**: Use `tail` to see application output and debug messages

### After Completing Work

1. **Cancel background processes**: Use `cancelCommand` before deleting
2. **Clean up terminals**: Delete terminals that are no longer needed
3. **Verify builds**: Run final build verification before considering work complete

## Error Recovery

### When Processes Hang

```typescript
// 1. Try canceling gracefully
terminal-tools_cancelCommand(terminalName: "dev-server")

// 2. If that fails, delete and recreate
terminal-tools_deleteTerminal(name: "dev-server")
terminal-tools_createTerminal(name: "dev-server")
```

### When Output Is Too Large

Terminal output is truncated at 60KB. For large outputs, use tee for dual output:

```bash
# Output to BOTH console and log file
terminal-tools_sendCommand(
  terminalName: "build",
  command: "cd design && ./gradlew build 2>&1 | tee build.log"
)
# Console shows output (may be truncated), file has complete history

# Then use tail/grep to extract relevant parts from log file
run_in_terminal(
  command: "tail -n 50 build.log",
  explanation: "Get last 50 lines of build output"
)

# Or search for specific patterns
run_in_terminal(
  command: "grep -E 'ERROR|FAILURE|SUCCESS' build.log | tail -n 20",
  explanation: "Extract build status indicators"
)
```

## Integration with Other Tools

### With Task Management

When using `manage_todo_list`:

```typescript
// Mark task in-progress when starting terminal work
manage_todo_list(
  operation: "write",
  todoList: [
    {id: 1, title: "Build design service", status: "in-progress"}
  ]
)

// Start the build
terminal-tools_sendCommand(...)

// Mark complete after success
manage_todo_list(
  operation: "write",
  todoList: [
    {id: 1, title: "Build design service", status: "completed"}
  ]
)
```

### With File Operations

Chain terminal and file operations:

```typescript
// 1. Edit files
replace_string_in_file(...)

// 2. Verify build
terminal-tools_sendCommand(
  terminalName: "build",
  command: "cd design && ./gradlew build",
  captureOutput: true
)

// 3. Check for errors
get_errors()
```

## Common Pitfalls

❌ **Don't**: Use `run_in_terminal` for dev servers - context is lost
✅ **Do**: Use `terminal-tools_sendCommand` with named terminals

❌ **Don't**: Start multiple servers in same terminal
✅ **Do**: Use different terminal names for different servers

❌ **Don't**: Restart watch mode after every file change
✅ **Do**: Start once with `tee` for dual output (console + log file), then check log after changes

❌ **Don't**: Read entire watch log file to check status
✅ **Do**: Use `tail -n 100` + `grep` to extract latest build section only

❌ **Don't**: Act on old error messages from previous builds
✅ **Do**: Search for patterns from end of log - most recent result only

❌ **Don't**: Check log immediately after file save - rebuild hasn't started yet
✅ **Do**: Wait 2-5 seconds for watch process to detect change and rebuild

❌ **Don't**: Look for build status anywhere in log file
✅ **Do**: Find LAST rebuild marker, then check text that comes AFTER it

❌ **Don't**: Assume build is complete if you see "Change detected" marker
✅ **Do**: Verify there's build result text AFTER the marker; if not, still building

❌ **Don't**: Use `get_terminal_output` for watch processes - output may be truncated
✅ **Do**: Use `tee` to write to log file, then use `tail`/`grep` for pattern extraction

❌ **Don't**: Forget to inform users about background processes
✅ **Do**: Tell users what's running and how to check/stop it

❌ **Don't**: Delete terminals with running processes without canceling
✅ **Do**: Cancel first, then delete

❌ **Don't**: Capture output for long-running processes
✅ **Do**: Run background, check output later with `get_terminal_output`
