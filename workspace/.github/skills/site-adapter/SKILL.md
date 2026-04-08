---
name: site-adapter
description: Use built-in site adapters for fast, reliable access to popular websites. Adapters are pre-built scripts that extract data from sites like Hacker News, Xiaohongshu, and WeChat without manual navigation. Use when the user asks about trending content, social media, news, or wants to interact with a known site. Triggers include "hacker news", "trending", "xiaohongshu", "小红书", "wechat", "微信", or names of supported sites.
---

# Site Adapters

Site adapters let you interact with popular websites instantly — no manual clicking needed.

## List Available Adapters

```
site list
```

This shows all registered sites and their actions.

## Using an Adapter

```
site SITE_NAME ACTION_NAME
```

### Hacker News (no login required)

```
# Top stories
site hackernews top limit=10

# Newest stories
site hackernews new limit=10

# Best stories
site hackernews best limit=10
```

### Xiaohongshu / 小红书 (login required)

```
# Browse trending notes
site xiaohongshu explore limit=10

# Search for notes
site xiaohongshu search query=咖啡推荐 limit=10

# View your profile
site xiaohongshu profile

# Open note creation page
site xiaohongshu post
```

### WeChat Web / 微信 (login required)

```
# Check login status
site wechat status

# List recent chats
site wechat chats

# Read messages from a contact
site wechat messages contact=联系人名字

# Send a message
site wechat send contact=联系人名字 message=你好
```

## Login Flow

Some sites require login. If an adapter says "Not logged in":

1. **Open login page**: `site SITE_NAME login`
2. **User logs in manually** in the browser view
3. **Verify**: `site SITE_NAME auth_check`
4. **Use the adapter** — cookies persist, so login is one-time

Check all login sessions:
```
site sessions
```

## When to Use Adapters vs Manual Navigation

| Situation | Use |
|-----------|-----|
| Get Hacker News top stories | `site` adapter (fast, structured data) |
| Browse Xiaohongshu trending | `site` adapter |
| Read a specific article URL | `navigate` + `snapshot` |
| Fill out a form | `navigate` + `snapshot` + `type` + `click` |
| Search Google/Baidu | `navigate` (use web-search skill) |

**Prefer adapters** when available — they are faster and return clean, structured data.
**Fall back to navigate + snapshot** for sites without adapters or custom actions.
