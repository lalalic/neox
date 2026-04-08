---
name: youtube
description: Search and browse YouTube videos using the web browser. Use when the user wants to find videos, watch tutorials, search YouTube, or get video information. Triggers include "find video", "YouTube", "watch", "tutorial", "video about".
---

# YouTube via Browser

Search and browse YouTube videos through the web browser.

## Search for Videos

```
web-agent navigate url=https://www.youtube.com/results?search_query=YOUR+SEARCH+TERMS
web-agent snapshot
# Read video titles, channels, and view counts from results
```

### With Filters

Add filter params to narrow results:
- Recent uploads: append `&sp=CAI%253D`
- This week: append `&sp=EgIIAw%253D%253D`
- Sort by view count: append `&sp=CAMSAhAB`

```
web-agent navigate url=https://www.youtube.com/results?search_query=react+tutorial&sp=CAI%253D
web-agent snapshot
```

## Get Video Details

```
# Click on a video from search results
web-agent click ref=rN
web-agent snapshot
# Read title, channel, description, view count, publish date
```

## Read Video Description

```
# On a video page, expand the description
web-agent snapshot
# Find "...more" or description expand button
web-agent click ref=rN
web-agent snapshot
```

## Browse Channel Content

```
web-agent navigate url=https://www.youtube.com/@CHANNEL_NAME/videos
web-agent snapshot
# See recent uploads from a channel
```

## Get Trending Videos

```
web-agent navigate url=https://www.youtube.com/feed/trending
web-agent snapshot
```

## Tips

1. YouTube works without login for searching and browsing
2. Use specific search terms for better results
3. Check view count and publish date to judge relevance
4. Read video descriptions for links, timestamps, and resources
5. For downloading audio, see the free-bgm skill
