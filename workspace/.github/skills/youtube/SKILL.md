---
name: youtube
description: Search and browse YouTube videos using the web browser. Use when the user wants to find videos, watch tutorials, search YouTube, or get video information. Triggers include "find video", "YouTube", "watch", "tutorial", "video about".
---

# YouTube via Browser

Search and browse YouTube videos through the web browser.

## Search for Videos

```
web_navigate url=https://www.youtube.com/results?search_query=YOUR+SEARCH+TERMS
web_snapshot
# Read video titles, channels, and view counts from results
```

### With Filters

Add filter params to narrow results:
- Recent uploads: append `&sp=CAI%253D`
- This week: append `&sp=EgIIAw%253D%253D`
- Sort by view count: append `&sp=CAMSAhAB`

```
web_navigate url=https://www.youtube.com/results?search_query=react+tutorial&sp=CAI%253D
web_snapshot
```

## Get Video Details

```
# Click on a video from search results
web_click ref=rN
web_snapshot
# Read title, channel, description, view count, publish date
```

## Read Video Description

```
# On a video page, expand the description
web_snapshot
# Find "...more" or description expand button
web_click ref=rN
web_snapshot
```

## Browse Channel Content

```
web_navigate url=https://www.youtube.com/@CHANNEL_NAME/videos
web_snapshot
# See recent uploads from a channel
```

## Get Trending Videos

```
web_navigate url=https://www.youtube.com/feed/trending
web_snapshot
```

## Tips

1. YouTube works without login for searching and browsing
2. Use specific search terms for better results
3. Check view count and publish date to judge relevance
4. Read video descriptions for links, timestamps, and resources
5. For downloading audio, see the free-bgm skill
