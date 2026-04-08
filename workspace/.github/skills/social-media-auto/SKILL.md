---
name: social-media-auto
description: Automated social media account maintenance — post, monitor engagement, reply to comments, analyze feedback, improve future content. Works with 小红书, Twitter, YouTube, TikTok, WeChat video via WebKitAgent.
---

# Social Media Auto-Maintenance

Automated social media lifecycle: **post → monitor → reply → feedback → improve → post**.

## Platforms

| Platform | Post URL | Creator URL |
|----------|----------|-------------|
| 小红书 | creator.xiaohongshu.com | creator.xiaohongshu.com/publish/publish |
| Twitter/X | x.com/compose/post | x.com/home |
| YouTube | studio.youtube.com | studio.youtube.com/channel/videos |
| WeChat 视频号 | channels.weixin.qq.com | channels.weixin.qq.com/platform |
| TikTok | tiktok.com/creator | tiktok.com/upload |

## Workflow Phases

### 1. Post Content
Use `web_agent` to navigate to platform's creator page, fill in content, upload media, and publish.

**Critical limits:**
| Platform | Title Limit | Key Gotcha |
|----------|-------------|------------|
| 小红书 | 20 chars | Silent draft save if exceeded |
| WeChat 视频号 | 6-16 chars | Min 6 chars required |
| Twitter | 140 chars | Use threads for longer |
| YouTube | 100 chars | Wait for "Checks complete" |

### 2. Monitor Engagement
After posting, periodically check:
- View count, likes, comments, shares
- Navigate to post analytics page
- Record metrics in session memory

### 3. Reply to Comments
- Navigate to comments section
- Read new comments
- Generate contextual replies
- Post replies via web_agent

### 4. Analyze Feedback
- Which posts performed well? Why?
- What topics/formats get most engagement?
- What time of day works best?
- Store insights in memory for next cycle

### 5. Improve Next Post
- Use feedback data to guide content creation
- A/B test different hooks, formats, lengths
- Track improvement over time

## Using web_agent

Navigate to platform:
```
web_navigate url=https://creator.xiaohongshu.com
```

Take snapshot to understand page (returns text + refs like r0, r1, r2...):
```
web_snapshot
```

Type into a field:
```
web_type ref=r3 text=Your content here
```

Click buttons:
```
web_click ref=r5
```

Upload files:
```
web_upload ref=r7 filePath=/path/to/file
```

## Tips
- Always check login status before posting
- Don't post too frequently (platform rate limits)
- Keep a posting schedule in memory
- Track metrics over time to measure growth
- Only 1 self-comment per post on 小红书 (3 looks spammy)
- 文字配图 cover: only HOOK text (6-20 words), NOT full content
