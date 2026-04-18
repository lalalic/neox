---
name: video-intents
description: Intent recognition templates that map user requests to production approaches. Use during Phase 1 (Assess) to interpret what the user wants.
---

# Video Intent Templates

## When to Use
Use during Phase 1 (Assess) after receiving the user's prompt and observing the environment. Match the user's words and context to an intent category, then use the associated approach to guide planning.

## Intent Categories

### 1. Product Showcase
**Trigger words**: product, review, unboxing, showcase, demo, feature, comparison, specs
**Environment clues**: object on table, package, device, product packaging

**Approach**:
- Phase: 7 shots using `product-demo` template
- Style: Clean, well-lit, focused on details
- Audio: Upbeat instrumental BGM, no voiceover unless requested
- Edit: Medium pace, 3–4 sec per shot, smooth transitions
- Remotion: Title card → clip sequence → lower third with product name → end card

### 2. Tutorial / How-To
**Trigger words**: how to, tutorial, teach, explain, show me, step by step, guide, DIY
**Environment clues**: workspace, tools, ingredients, materials laid out

**Approach**:
- Phase: 9 shots using `tutorial` template
- Style: Clear framing, well-lit hands and workspace
- Audio: Calm background music, space for future voiceover
- Edit: Deliberate pace, 4–6 sec per shot, clear step transitions
- Remotion: Title → step-by-step clips with number overlays → result shot → outro

### 3. Vlog / Story
**Trigger words**: day, vlog, story, about my, life, journey, adventure, explore
**Environment clues**: outdoor, multiple locations, moving

**Approach**:
- Phase: 10+ shots using `vlog` template
- Style: Dynamic, natural lighting, variety of angles
- Audio: Upbeat or chill BGM matching mood
- Edit: Fast pace for energy or slow for contemplative, 2–4 sec cuts
- Remotion: Quick title → clip montage with music → text overlays → outro

### 4. Food / Cooking
**Trigger words**: cook, recipe, food, eat, bake, meal, ingredients, kitchen
**Environment clues**: kitchen, food items, cooking equipment, dining table

**Approach**:
- Phase: 7 shots using `food` template
- Style: Warm tones, close-ups of textures, overhead shots
- Audio: Light acoustic or jazz BGM
- Edit: Medium pace, emphasize sizzle/texture moments with slow-mo feel
- Remotion: Ingredient reveal → cooking montage → plating → hero shot → credits

### 5. Short Film / Narrative
**Trigger words**: story, film, scene, character, drama, act, plot, cinematic
**Environment clues**: interesting lighting, dramatic setting, people

**Approach**:
- Phase: 11+ shots using `short-film` template
- Style: Cinematic framing, dramatic angles, intentional lighting
- Audio: Mood-matching score, consider silence for tension
- Edit: Varied pacing — slow for tension, quick for action
- Remotion: Establishing → narrative clips → climax → resolution → credits roll

### 6. Interview / Testimonial
**Trigger words**: interview, talk, discuss, testimonial, Q&A, conversation, opinion
**Environment clues**: person sitting, office/room background, two people facing each other

**Approach**:
- Phase: 5 shots using `interview` template
- Style: Stable framing, clean background, good audio focus
- Audio: Minimal or no BGM (conversation is primary)
- Edit: Long takes, cut to B-roll for transitions
- Remotion: Name lower third → interview clips → B-roll inserts → end card

### 7. Quick Social / Reel
**Trigger words**: quick, short, reel, TikTok, clip, 30 seconds, fast, trending
**Environment clues**: any — this is more about user's desired output format

**Approach**:
- Phase: 3–5 quick shots, custom plan
- Style: Vertical (9:16) if possible, punchy, attention-grabbing
- Audio: Trending or energetic BGM
- Edit: Very fast, 1–2 sec per shot, beat-matched cuts
- Remotion: Hook shot → rapid clips → text punchline → end

### 8. Nature / Scenic
**Trigger words**: nature, landscape, scenery, beautiful, sunset, peaceful, view, sky
**Environment clues**: outdoor, trees, sky, water, mountains

**Approach**:
- Phase: 6–8 shots, focus on wide + panning
- Style: Long holds, slow pans, let the scene breathe
- Audio: Ambient/nature sounds + soft instrumental
- Edit: Slow pace, 5–8 sec per shot, fade transitions
- Remotion: Wide establishing → slow pan clips → detail inserts → final wide → text overlay

### 9. Event Coverage
**Trigger words**: event, party, wedding, birthday, celebration, meeting, conference
**Environment clues**: crowd, decorations, stage, food tables

**Approach**:
- Phase: 10+ shots, run-and-gun style
- Style: Mix of wide and candid close-ups, capture moments
- Audio: Event audio + subtle BGM underneath
- Edit: Medium-fast, 2–3 sec per shot, chronological
- Remotion: Opening title with date → clip montage → highlight moments → thank you card

### 10. Free-form / Ambient
**Trigger words**: look around, suggest, surprise me, anything, random, explore
**Environment clues**: agent observes and decides

**Approach**:
- Phase: Use `observe_camera` + `listen` first, then pick the best-matching template above
- Style: Determined by what's interesting in the environment
- The agent should describe what it sees and propose a concept before planning

## Intent Resolution Flow

```
1. Parse user text for trigger words
2. Call observe_camera to see the environment
3. Call listen to hear ambient audio context
4. Match to intent category (or combine)
5. Propose concept to user via ask_user
6. On confirmation, load matching shot-planning template
7. Adapt template to specific context (rename shots, adjust descriptions)
8. Call production_state(command: 'plan_shots', shots: [...])
```

## Combining Intents
Users often combine intents. Common combos:
- **"Cook and film a recipe tutorial"** → Food + Tutorial → Use food template but add presenter intro/outro
- **"Short cinematic vlog of my morning"** → Vlog + Narrative → Vlog structure with cinematic angles
- **"Quick product demo for Instagram"** → Product + Quick Social → Product shots but fast-paced, vertical

When intents overlap, use the primary intent's shot template but apply the secondary intent's style/pacing.
