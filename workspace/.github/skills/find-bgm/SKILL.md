---
name: find-bgm
description: Find and download free background music for video productions. Use when the agent needs music for a video composition.
---

# Find Background Music

## When to Use
Use this skill when the production plan includes background music or sound effects. Run during Phase 2 (Plan) or Phase 5 (Produce).

## Free Music Sources

### YouTube Audio Library
- Navigate to https://studio.youtube.com/channel/UC/music
- Filter by genre, mood, duration
- All tracks are royalty-free for YouTube use
- Download directly via the download button

### Pixabay Music
- Navigate to https://pixabay.com/music/
- Search by mood: "cinematic", "upbeat", "calm", "dramatic"
- All tracks are free for commercial use (no attribution required)
- Download via the download button on each track page

### Bensound
- Navigate to https://www.bensound.com/
- Browse by category: cinematic, corporate, electronica, acoustic
- Free with attribution (Creative Commons license)
- Premium tracks available without attribution

### Freesound
- Navigate to https://freesound.org/
- Best for sound effects (whoosh, click, ambient)
- Search by tag and filter by license (CC0 for no attribution)
- Requires account for download

## Workflow

1. **Identify mood** — Based on the video's intent and content, decide the mood:
   - Energetic/upbeat → action, sports, product launch
   - Calm/ambient → nature, meditation, documentary
   - Cinematic/dramatic → narrative, short film, trailer
   - Corporate/clean → explainer, tutorial, business

2. **Search** — Use web_agent to navigate to a source and search:
   ```
   web_agent(command: "navigate", url: "https://pixabay.com/music/search/cinematic/")
   web_agent(command: "snapshot")
   ```

3. **Preview** — Read track names and descriptions from the snapshot to find good matches.

4. **Download** — Use web_agent download command:
   ```
   web_agent(command: "download", ref: "r12")
   ```

5. **Register** — Add the downloaded file as an asset:
   ```
   production_state(command: "add_asset", asset: {type: "audio", url: "https://...", description: "Calm piano background"})
   ```

6. **Use in composition** — Apply via video_add_audio or include in video_compose_dynamic JSX.

## Music Selection Tips

- Match tempo to video pacing (fast cuts → fast BPM, slow motion → slow BPM)
- Avoid tracks with vocals unless intentional
- Keep volume low enough that it doesn't compete with speech
- Consider using different tracks for different sections (intro vs. main vs. outro)
- 30-60 second tracks work well for short videos; loop if needed
