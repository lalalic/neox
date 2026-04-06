---
name: webkitagent
description: Browser automation on your phone using the web_agent tool. Use for any task that needs a web browser — visiting websites, filling forms, clicking buttons, reading page content, downloading files, taking screenshots, or running JavaScript. This is your gateway to the internet.
---

# WebKitAgent — Browser Automation

You have a `web_agent` tool that controls a built-in web browser. Use it to visit any website, read content, interact with pages, and more.

## Available Commands

| Command | What it does | Key params |
|---------|-------------|------------|
| `navigate` | Go to a URL | `url` |
| `snapshot` | Read the page — get text and clickable element refs (r0, r1, r2...) | — |
| `click` | Click an element | `ref` (e.g., "r5") |
| `type` | Type into a text field | `ref`, `text` |
| `download` | Download a file | `ref` or `url`, optional `filename` |
| `upload` | Upload a file | `ref`, `filePath` |
| `evaluate` | Run JavaScript on the page | `script` |
| `screenshot` | Take a photo of the page | — |
| `site` | Use a pre-built site adapter (fast shortcut) | `site`, `action` |

## Basic Workflow

```
1. Navigate to a page:
   web_agent command=navigate url=https://example.com

2. Read the page:
   web_agent command=snapshot
   → Returns page text + refs like r0, r1, r2 for clickable elements

3. Click something:
   web_agent command=click ref=r3

4. Type into a field:
   web_agent command=type ref=r1 text=Hello World

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
web_agent command=evaluate script=document.body.innerText
```

For structured data:

```
web_agent command=evaluate script=JSON.stringify({title:document.title,text:document.querySelector('article')?.innerText})
```

## Downloading Files

```
# By clicking a download link
web_agent command=download ref=r7

# By direct URL
web_agent command=download url=https://example.com/file.pdf filename=report.pdf
```

## Taking Screenshots

```
web_agent command=screenshot
```

Returns a base64 image you can describe or analyze.
