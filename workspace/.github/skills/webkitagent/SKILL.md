---
name: webkitagent
description: Browser automation on your phone using the web-agent and site CLI commands via run_in_terminal. Use for any task that needs a web browser — visiting websites, filling forms, clicking buttons, reading page content, downloading files, taking screenshots, or running JavaScript. This is your gateway to the internet.
---

# WebKitAgent — Browser Automation

You have `web-agent` and `site` CLI commands (used via `run_in_terminal`) that control a built-in web browser.

## web-agent Commands

| Command | What it does | Example |
|---------|-------------|---------|
| `navigate` | Go to a URL | `web-agent navigate https://example.com` |
| `snapshot` | Read the page — get text and clickable element refs (r0, r1, r2...) | `web-agent snapshot` |
| `click` | Click an element | `web-agent click r5` |
| `type` | Type into a text field | `web-agent type r1 Hello World` |
| `download` | Download a file | `web-agent download r3 output.mp3` |
| `upload` | Upload a file | `web-agent upload r2 /path/to/file` |
| `evaluate` | Run JavaScript on the page | `web-agent evaluate document.title` |
| `screenshot` | Take a photo of the page | `web-agent screenshot` |

## site Commands (for known sites)

| Command | Example |
|---------|---------|
| `site list` | List all available adapters |
| `site sessions` | Check login status for all sites |
| `site <name> <action>` | `site hackernews top limit=5` |
| `site <name> login` | `site twitter login` |
| `site <name> auth_check` | `site twitter auth_check` |

## Basic Workflow

```
1. Navigate to a page:
   web-agent navigate https://example.com

2. Read the page:
   web-agent snapshot
   → Returns page text + refs like r0, r1, r2 for clickable elements

3. Click something:
   web-agent click r3

4. Type into a field:
   web-agent type r1 Hello World

5. Snapshot again after any action to see what changed
```

## Important Rules

1. **Always snapshot after navigate** — this shows you the page content
2. **Always snapshot after click** — the page may have changed
3. **Refs change** after each snapshot — always use fresh refs
4. **Use `site` command** for known sites instead of manual navigation

## Reading Page Content

Snapshot gives you formatted text. For more content:

```
web-agent evaluate document.body.innerText
```

For structured data:

```
web-agent evaluate JSON.stringify({title:document.title,text:document.querySelector('article')?.innerText})
```

## Downloading Files

```
# By clicking a download link
web-agent download r7

# By direct URL
web-agent download https://example.com/file.pdf report.pdf
```

## Taking Screenshots

```
web-agent screenshot
```

Returns a base64 image you can describe or analyze.
