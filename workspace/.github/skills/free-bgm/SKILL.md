---
name: free-bgm
description: Find and download free background music and sound effects for video projects. Use when the user asks for music, BGM, sound effects, royalty-free audio, or needs audio for a video. Sources include YouTube Audio Library, Bensound, Freesound, and Pixabay.
---

# Free Background Music & Sound Effects

Find and download royalty-free music using the web browser.

## Sources

| Source | URL | Auth | License |
|--------|-----|------|---------|
| YouTube Audio Library | studio.youtube.com/channel/UC/music | YouTube login | Free, some need attribution |
| Pixabay Music | pixabay.com/music | None | Free for any use |
| Bensound | bensound.com | None for free tier | CC with attribution |
| Freesound | freesound.org | Account for download | CC (varies) |

## Workflow

### 1. Search for Music

**Pixabay (easiest, no login):**
```
web_navigate url=https://pixabay.com/music/search/YOUR%20SEARCH%20TERM/
web_snapshot
# Browse results, click a track to preview
web_click ref=rN
web_snapshot
# Find download button
web_click ref=rN
```

**YouTube Audio Library (best selection, needs login):**
```
web_navigate url=https://studio.youtube.com/channel/UC/music
web_snapshot
# Use filters to search by genre, mood, duration
```

**Bensound:**
```
web_navigate url=https://www.bensound.com/free-music-for-videos
web_snapshot
```

### 2. Download

```
# Download from a link
web_download ref=rN filename=bgm-track-name.mp3

# Or from direct URL
web_download url=https://example.com/track.mp3 filename=bgm-gentle-piano.mp3
```

### 3. Save Metadata

After downloading, note in the project:
- **Source**: where you got it
- **Title**: the track name
- **Author**: who made it
- **License**: attribution requirement
- **Attribution text**: e.g., "Music by Author via Source (License)"

## File Organization

Put downloaded music in the project's media folder:
```
music/
  bgm-gentle-piano.mp3
  sfx-notification.wav
```

## Licensing Rules

- **No attribution needed**: Most Pixabay tracks
- **Attribution needed**: Bensound free tier, some YouTube Audio Library tracks
- **Always check**: Read the license on the download page before using
