---
name: site-adapter
description: Use built-in site adapters for fast, reliable access to popular websites. Adapters are pre-built scripts that extract data from sites like Hacker News, Xiaohongshu, and WeChat without manual navigation. Use when the user asks about trending content, social media, news, or wants to interact with a known site. Triggers include "hacker news", "trending", "xiaohongshu", "小红书", "wechat", "微信", or names of supported sites.
---

# Site Adapters

Site adapters let you interact with popular websites instantly — no manual clicking needed.

## List Available Adapters

```
web_site action=list
```

This shows all registered sites and their actions.

## Using an Adapter

```
web_site site=SITE_NAME action=ACTION_NAME
```

### Hacker News (no login required)

```
# Top stories
web_site site=hackernews action=top limit=10

# Newest stories
web_site site=hackernews action=new limit=10

# Best stories
web_site site=hackernews action=best limit=10
```

### Xiaohongshu / 小红书 (login required)

```
# Browse trending notes
web_site site=xiaohongshu action=explore limit=10

# Search for notes
web_site site=xiaohongshu action=search query=咖啡推荐 limit=10

# View your profile
web_site site=xiaohongshu action=profile

# Open note creation page
web_site site=xiaohongshu action=post
```

### WeChat Web / 微信 (login required)

```
# Check login status
web_site site=wechat action=status

# List recent chats
web_site site=wechat action=chats

# Read messages from a contact
web_site site=wechat action=messages contact=联系人名字

# Send a message
web_site site=wechat action=send contact=联系人名字 message=你好
```

## Login Flow

Some sites require login. If an adapter says "Not logged in":

1. **Open login page**: `web_site site=SITE_NAME action=login`
2. **User logs in manually** in the browser view
3. **Verify**: `web_site site=SITE_NAME action=auth_check`
4. **Use the adapter** — cookies persist, so login is one-time

Check all login sessions:
```
web_site action=sessions
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
