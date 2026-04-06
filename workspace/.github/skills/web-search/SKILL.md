---
name: web-search
description: Search the web and fetch page content using web_agent tool. Use when you need to find information online, look up documentation, research topics, check facts, or get current data from the internet. Triggers include "search for", "look up", "find online", "what is", "google", "baidu", questions about current events, or any request requiring web information.
---

# Web Search & Fetch

Use your `web_agent` tool to search the web and read page content.

## Quick Search (Google)

```
web_agent command=navigate url=https://www.google.com/search?q=YOUR+SEARCH+QUERY
web_agent command=snapshot
# Read search results from the snapshot
# Click on a result ref to read the full page
web_agent command=click ref=rN
web_agent command=snapshot
```

## Quick Search (Baidu — for Chinese queries)

```
web_agent command=navigate url=https://www.baidu.com/s?wd=你的搜索词
web_agent command=snapshot
web_agent command=click ref=rN
web_agent command=snapshot
```

## Fetch a Specific Page

```
web_agent command=navigate url=https://example.com/article
web_agent command=snapshot
# snapshot gives you the page text and interactive elements
```

## Extract Page Content with JavaScript

When snapshot doesn't capture enough text, use evaluate to extract content:

```
web_agent command=evaluate script=document.body.innerText
```

Or extract structured data:

```
web_agent command=evaluate script=JSON.stringify({title:document.title,text:document.querySelector('article')?.innerText||document.body.innerText})
```

## Workflow Tips

1. **Always snapshot after navigate** — this gives you the page content and clickable refs
2. **Click search results** — use the ref from snapshot (e.g., `r3`) to open a result
3. **Snapshot again** after clicking to read the destination page
4. **Use Google for English**, **Baidu for Chinese** queries
5. **Extract text** with `evaluate` if the snapshot is too cluttered
6. **Take screenshots** with `web_agent command=screenshot` if you need to see visual layout

## Common Patterns

### Research a topic
1. Search Google/Baidu
2. Snapshot to read results
3. Click the most relevant result
4. Snapshot to read the article
5. Repeat for additional sources

### Check current information
1. Navigate directly to a known source (e.g., weather site, news site)
2. Snapshot to read content

### Download a file from the web
```
web_agent command=download url=https://example.com/file.pdf
```
