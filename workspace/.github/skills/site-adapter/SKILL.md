---
name: site-adapter
description: Fast access to popular websites via site CLI. Use when user mentions a known site like Hacker News, Xiaohongshu, WeChat.
---

# site CLI

Structured access to known websites via `run_in_terminal`.

```
site list                            # show all adapters
site sessions                        # check login status
site <name> <action> [params]        # run an action
site <name> login                    # open login page
site <name> auth_check               # verify login
```

Examples:
```
site hackernews top limit=5
site xiaohongshu explore limit=10
site wechat chats
```

If a site needs login: `site <name> login` → user logs in → `site <name> auth_check`.

Use `site` for known sites. Fall back to `web-agent` for everything else.
