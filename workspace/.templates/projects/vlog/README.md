# goal
Create vlogs from daily photos and videos — curate, edit, add music, and publish.

# feature
- [ ] Import photos/videos from camera roll
- [ ] Auto-curate and storyboard from day's media
- [ ] Add background music and transitions 
- [ ] Generate captions and thumbnails
- [ ] Publish to social platforms

# strategy
Use media from today's photos/videos, auto-arrange with AI narration, add BGM via free-bgm skill, and export/publish using social-media-auto skill.

# implementation phrases
- [ ] Import today's media
- [ ] Create storyboard
- [ ] Edit and add music
- [ ] Generate captions
- [ ] Publish

# onboarding
Ask the user:
1. What topic for your vlogs?
2. Where to publish? (YouTube, TikTok, 小红书)
3. Do you have footage already, or need help generating?

# human-must
| When | What |
|------|------|
| Setup | Describe video style/topic |
| Per video | Shoot raw footage (if not AI-generated) |
| Per video | Record voiceover (if needed) |
| Per video | Approve final cut before publishing |

# daily-assist
- Track production pipeline: script → shoot → edit → publish
- "Your script for Episode N is ready. Time to shoot!"

# references
- **media/**: raw photos and video clips
- **edits/**: edited vlogs and drafts
- **docs/**: style guides, music choices
- **progress/**: publish schedule, performance
