---
name: nlm-xhs-pipeline
description: "End-to-end pipeline: find YouTube videos on a topic → download & cut clips → feed into NotebookLM → generate podcast audio → compose Remotion video (NLM audio + YT clips) → publish as XHS video post. Use when: 'make XHS post from topic', 'nlm to xhs', 'create video post', 'podcast to xhs'."
---

# NLM → XHS Video Pipeline

Fully automated pipeline that turns a topic into a published XHS video post
using NotebookLM podcast audio + YouTube clip visuals.

## Pipeline Steps

### Step 0: Find Trending Topics on XHS (with 筛选 filter)
Search XHS for a topic and use the "筛选" dropdown to sort by "最多评论" or "最多点赞".

**IMPORTANT**: Use `cdp()` directly instead of `js()` for XHS pages. `js()` may fail with "No target with given id found".

```python
# browser-harness script
import json, time

# 1. Navigate to search
goto_url("https://www.xiaohongshu.com/search_result?keyword=YOUR_KEYWORD&source=web_search_result_notes&type=general")
time.sleep(5)

# 2. Hover on 筛选 to reveal sort options
# Find 筛选 position first
filter_pos = cdp("Runtime.evaluate", expression="""
var els = Array.from(document.querySelectorAll("*"));
var el = els.find(e => e.textContent.trim() === "\\u7b5b\\u9009" && e.children.length === 0);
el ? JSON.stringify({x: el.getBoundingClientRect().x + el.getBoundingClientRect().width/2, y: el.getBoundingClientRect().y + el.getBoundingClientRect().height/2}) : "null"
""", returnByValue=True)
pos = json.loads(filter_pos["result"]["value"])

# 3. Hover to show dropdown
cdp("Input.dispatchMouseEvent", type="mouseMoved", x=int(pos["x"]), y=int(pos["y"]))
time.sleep(1)

# 4. Find and click "最多评论" or "最多点赞"
target_pos = cdp("Runtime.evaluate", expression="""
var els = Array.from(document.querySelectorAll("*"));
var el = els.find(e => e.textContent.trim() === "\\u6700\\u591a\\u8bc4\\u8bba" && e.children.length === 0);
el ? JSON.stringify({x: el.getBoundingClientRect().x + el.getBoundingClientRect().width/2, y: el.getBoundingClientRect().y + el.getBoundingClientRect().height/2}) : "null"
""", returnByValue=True)
tpos = json.loads(target_pos["result"]["value"])
cdp("Input.dispatchMouseEvent", type="mousePressed", x=int(tpos["x"]), y=int(tpos["y"]), button="left", clickCount=1)
cdp("Input.dispatchMouseEvent", type="mouseReleased", x=int(tpos["x"]), y=int(tpos["y"]), button="left", clickCount=1)
time.sleep(3)

# 5. Get sorted results
result = cdp("Runtime.evaluate", expression="""
JSON.stringify(Array.from(document.querySelectorAll("section.note-item")).slice(0, 10).map(el => {
    const titleEl = el.querySelector("a.title span");
    const coverEl = el.querySelector("a.cover");
    const likeEl = el.querySelector("span.count");
    return {title: titleEl ? titleEl.textContent.trim() : "", href: coverEl ? coverEl.href : "", likes: likeEl ? likeEl.textContent.trim() : ""};
}).filter(r => r.title))
""", returnByValue=True)
data = json.loads(result["result"]["value"])
for d in data:
    print(d["likes"], "|", d["title"][:60])
```

### Step 0b: Scrape Post Content + Comments from XHS
Navigate to search, click on posts via overlay to extract content and comments.

**Key**: Navigate back to search URL between each post to avoid stale overlays.

```python
# For each post index (0..4):
goto_url(search_url)  # Navigate fresh each time
time.sleep(4)
cdp("Runtime.evaluate", expression="document.querySelectorAll('a.cover')[IDX]?.click(); true", returnByValue=True)
time.sleep(4)
# Scroll for comments
cdp("Runtime.evaluate", expression="var s = document.querySelector('.note-scroller'); if(s) s.scrollTop = s.scrollHeight;")
time.sleep(2)
# Extract
content = cdp("Runtime.evaluate", expression="""
JSON.stringify({
    title: document.querySelector(".note-content .title, .note-scroller .title")?.textContent?.trim() || "",
    desc: document.querySelector(".note-content .desc, .note-scroller .desc")?.textContent?.trim() || "",
    comments: Array.from(document.querySelectorAll(".parent-comment .content, .comment-item .content")).slice(0, 20).map(el => el.textContent?.trim()).filter(t => t && t.length > 3)
})
""", returnByValue=True)
```

Save scraped posts as markdown file for NLM source.
'
```

Save trending insights to a markdown file for NLM:

```bash
# Save trending insights for NLM
cat > /tmp/nlm-xhs/xhs-trends.md << 'EOF'
# XHS Trending Topics - <date>

## Topic 1: <title>
- URL: https://www.xiaohongshu.com/explore/<id>
- Key points: ...
- Engagement: X likes, Y comments
- Why it works: ...

## Topic 2: ...
EOF
```

### Step 1: Find YouTube Videos
Search YouTube for relevant videos on the topic. Download 3-5 short videos.

```bash
# Search and list results
yt-dlp --flat-playlist "ytsearch5:<topic>" --print "%(id)s %(title)s %(duration)s"

# Download best quality (max 720p to save space), trim to clips later
yt-dlp -f "bestvideo[height<=720]+bestaudio/best[height<=720]" \
  --merge-output-format mp4 \
  -o "/tmp/nlm-xhs/clips/%(id)s.mp4" \
  "https://youtube.com/watch?v=<id>"
```

### Step 2: Cut Clips
Use ffmpeg to extract 10-30s highlight clips from each downloaded video.
Pick visually interesting segments (intros, demos, key moments).

```bash
# Cut a clip: start at 30s, duration 15s
ffmpeg -ss 30 -i /tmp/nlm-xhs/clips/VIDEO_ID.mp4 \
  -t 15 -c copy /tmp/nlm-xhs/clips/VIDEO_ID_clip1.mp4
```

Aim for **4-8 clips** totaling the expected podcast audio duration (~3-5 min).

### Step 3: Feed Sources into NotebookLM
Create a notebook and add sources (video URLs, articles, transcripts, XHS trends).

```bash
# Create notebook
nlm create notebook "<Topic> Research"

# Add YouTube video URLs as sources (NLM extracts transcripts)
nlm source add <notebook-id> -y "https://youtube.com/watch?v=<id1>" -y "https://youtube.com/watch?v=<id2>" --wait

# Add XHS trending insights
nlm source add <notebook-id> --file /tmp/nlm-xhs/xhs-trends.md

# Add any additional articles or text
nlm source add <notebook-id> --url "https://article-url.com"
nlm source add <notebook-id> --text "Additional context..." --title "Notes"
```

### Step 4: Generate Podcast Audio
Use NLM studio to create a podcast-style audio summary.

```bash
# Generate audio (takes 2-5 min)
nlm create audio <notebook-id> --language zh --length default --focus "<topic focus>" -y

# Check status (poll every 30s — NLM may report "completed" before download is ready)
nlm studio status <notebook-id>

# Wait ~60s after status shows completed, then download (output is .m4a not .mp3)
nlm download audio <notebook-id> -o /tmp/nlm-xhs/podcast.m4a
```

### Step 5: Get Audio Duration & Plan Video
```bash
# Get podcast duration
ffprobe -v quiet -show_entries format=duration \
  -of csv=p=0 /tmp/nlm-xhs/podcast.m4a
```

Distribute clips evenly across the audio duration. Each clip should be
10-30s with crossfade transitions.

### Step 6: Compose Video with Remotion Engine

Create a stream tree JSON that layers the NLM podcast audio over the
YouTube clips as visual B-roll.

```bash
cd ~/.remotion-engine

cat > /tmp/nlm-xhs/video.json << 'STREAM'
{
  "type": "root",
  "width": 1080,
  "height": 1920,
  "fps": 30,
  "isSeries": true,
  "children": [
    {
      "type": "audio",
      "src": "/tmp/nlm-xhs/podcast.m4a",
      "volume": 1.0
    },
    {
      "type": "folder",
      "name": "scene-1",
      "duration": "15s",
      "transition": {"type": "fade", "duration": "0.5s"},
      "children": [
        {"type": "video", "src": "/tmp/nlm-xhs/clips/clip1.mp4"}
      ]
    },
    {
      "type": "folder",
      "name": "scene-2",
      "duration": "20s",
      "transition": {"type": "slide-left", "duration": "0.5s"},
      "children": [
        {"type": "video", "src": "/tmp/nlm-xhs/clips/clip2.mp4"}
      ]
    }
  ]
}
STREAM

# Render
npx remotion render src/index.tsx Video \
  --props /tmp/nlm-xhs/video.json \
  --output /tmp/nlm-xhs/final.mp4
```

**Aspect ratio:** 9:16 (1080×1920) for XHS video posts.

**Remotion gotcha:** Video clips must be in `public/` as real files (not symlinks).
Copy clips there: `cp /tmp/nlm-xhs/clips/*.mp4 ~/.remotion-engine/public/`
Use relative paths in JSON (e.g. `"src": "clip01.mp4"` not `/tmp/...`).

#### Fallback: ffmpeg compose (no transitions, but reliable)
If Remotion has issues, use ffmpeg directly:

```bash
cd /tmp/nlm-xhs
# Create concat list
ls clips/clip*.mp4 | sort | sed 's/^/file /' > concat.txt

# Compose: concat clips + podcast audio, scale to 9:16
ffmpeg -y -f concat -safe 0 -i concat.txt \
  -i podcast.m4a \
  -vf "scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2" \
  -c:v libx264 -preset fast -crf 23 \
  -c:a aac -b:a 192k \
  -shortest -movflags +faststart \
  output/final.mp4
```

### Step 7: Generate XHS Post Copy
Query the notebook for post content:

```bash
nlm query notebook <notebook-id> \
  "Write a 小红书 post about this topic. Requirements:
   - Title: ≤20 Chinese characters, attention-grabbing hook
   - Body: 200-500 chars, conversational tone, emoji-rich
   - Include 5-8 relevant hashtags
   - Format: title on first line, body below, hashtags at end"
```

### Step 8: Publish to XHS
Use `browser-harness` to post the video:

```bash
browser-harness -c '
import json, time

# Navigate to XHS creator publish page
new_tab("https://creator.xiaohongshu.com/publish/publish")
wait_for_load()
time.sleep(3)
capture_screenshot("/tmp/nlm-xhs/publish-1.png")
'
```

Then upload the video file:
```bash
browser-harness -c '
import time
# Find the file input for video upload
# XHS uses a hidden file input — find it and set the file
file_input = js("document.querySelector(\"input[type=file]\")?.tagName")
if file_input:
    # Use the upload interaction skill
    upload_file("input[type=file]", "/tmp/nlm-xhs/final.mp4")
else:
    # Click the upload area first
    capture_screenshot("/tmp/nlm-xhs/publish-upload.png")
    # Find upload button coordinates from screenshot
    # click_at_xy(x, y)

time.sleep(5)  # Wait for video processing
capture_screenshot("/tmp/nlm-xhs/publish-2.png")
'
```

Fill in title and description (use JSON data file to avoid escaping issues):
```bash
# Write post data to temp file
cat > /tmp/nlm-xhs/post-data.json << 'EOF'
{
    "title": "<generated-title-max-20-chars>",
    "body": "<generated-body-with-hashtags>"
}
EOF

browser-harness -c '
import json, time

data = json.load(open("/tmp/nlm-xhs/post-data.json"))

# Fill title (contenteditable div)
js(f"""
document.querySelector(".c-input_inner, [placeholder*=\\"标题\\"]").value = {json.dumps(data["title"])};
document.querySelector(".c-input_inner, [placeholder*=\\"标题\\"]").dispatchEvent(new Event("input", {{bubbles: true}}));
""")

# Fill description
js(f"""
var desc = document.querySelector(".ql-editor, [contenteditable]");
if (desc) desc.textContent = {json.dumps(data["body"])};
""")

time.sleep(1)
capture_screenshot("/tmp/nlm-xhs/publish-3.png")

# Click publish button
# js("document.querySelector(\"button.publishBtn, .submit\").click()")
# Verify with screenshot before clicking publish
'
```

**XHS gotchas:**
- Title limit: 20 chars (silent draft save if exceeded!)
- Video must finish processing before title/desc fields appear
- Wait for upload progress to complete before filling fields
- Use JSON data file approach to avoid f-string escaping with CJK chars
- Always take screenshots to verify state before clicking publish
- Use `textContent=` for contenteditable divs, `.value=` for inputs

### Step 9: Monitor
Use `social-media-auto` skill to track engagement after posting.

## Quick Reference

| Tool | Purpose |
|------|---------|
| `yt-dlp` | Download YouTube videos |
| `ffmpeg` | Cut clips, probe duration |
| `nlm` | NotebookLM CLI (notebook, sources, audio) |
| Remotion Engine | Compose final video from clips + audio |
| `web-agent` / `browser-harness` | Post to XHS |

## Working Directory
All intermediate files go in `/tmp/nlm-xhs/`. Create subdirs:
```bash
mkdir -p /tmp/nlm-xhs/{clips,output}
```

## Notes
- NLM audio generation takes 2-5 minutes. Poll `nlm studio status` every 30s.
- **NLM download timing**: Status may show "completed" before download is ready. Wait ~60s after completion before downloading.
- YouTube clips should be royalty-free or fair-use (commentary/education).
- For Chinese-language topics, NLM generates Chinese podcast if sources are in Chinese.
- Always check `nlm login --check` before starting.
- If NLM audio is too long for XHS (>5 min), trim with ffmpeg before composing.
- For 5-minute target: use `--length default` (not `--length short` which gives ~4 min).
- **XHS search selectors**: Use `a.title` to extract post titles from search results.
- **Remotion Engine**: Must use `~/.remotion-engine` (symlink to actual project). Files must be real copies in `public/`, not symlinks.
- **ffmpeg fallback**: More reliable than Remotion for simple clip concat + audio overlay. Use Remotion only when transitions/overlays are needed.
- **Mixed codecs**: YouTube downloads may have h264, vp9, or av1. Concat demuxer fails with mixed codecs. Re-encode all clips to h264 first: `ffmpeg -y -i clip.mp4 -vf "scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2:black" -c:v libx264 -preset fast -crf 23 -an normalized_clip.mp4`
- **XHS scraping**: Direct URL navigation to `/explore/` or `/search_result/` posts shows "安全限制". Must use search page overlay approach: navigate to search URL, click `a.cover[N]`, read overlay content, then navigate back to search for next post.
- **browser-harness `js()` vs `cdp()`**: `js()` may fail with "No target with given id found". Use `cdp("Runtime.evaluate", expression=..., returnByValue=True)` directly after `switch_tab()` or `goto_url()`.
- **XHS source content quality**: Scrape top-commented posts with their comments as primary NLM sources. User requirement: content must be specific to characters/emotions, not generic.
- **zsh glob in `&&` chains**: `rm -f *.nonexistent` fails in zsh (no matches), breaking the whole chain. Don't use `rm -f glob` before files exist, or use `setopt NULL_GLOB`.
- **ffmpeg `-shortest` vs `-t 300`**: `-shortest` may produce shorter video than expected due to timestamp issues in concat. Use explicit `-t 300` for 5-min target.
