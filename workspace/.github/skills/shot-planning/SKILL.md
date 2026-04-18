---
name: shot-planning
description: Shot list planning templates for different video types. Use during Phase 2 (Plan) to generate structured shot lists.
---

# Shot Planning Templates

## When to Use
Use during Phase 2 (Plan) when calling `production_state(command: 'plan_shots')`. Pick the template closest to the user's intent and adapt it.

## Shot Types Reference

| Type | Code | Use For |
|------|------|---------|
| Wide / Establishing | `wide`, `establishing` | Opening shots, scene context, landscapes |
| Medium | `medium` | Conversations, presentations, general coverage |
| Close-up | `close_up` | Faces, emotions, details |
| Extreme Close-up | `extreme_close_up` | Fine detail, texture, dramatic emphasis |
| Over the Shoulder | `over_the_shoulder` | Dialogue, interviews, POV context |
| Low Angle | `low_angle` | Power, authority, dramatic |
| High Angle | `high_angle` | Vulnerability, overview, revealing layout |
| Tracking | `tracking` | Following movement, walk-and-talk |
| Panning | `panning` | Reveal, scene sweep, transitions |
| Tilting | `tilting` | Reveal height, buildings, full-body scan |
| Insert / Cutaway | `insert`, `cutaway` | Detail shots, B-roll, breaking up edits |

## Template: Product Demo (4–8 shots)

```json
[
  { "name": "product_hero", "type": "medium", "description": "Clean product shot on surface, well-lit", "camera": { "lens": "standard", "zoom": 1.0 } },
  { "name": "detail_texture", "type": "extreme_close_up", "description": "Texture / material close-up", "camera": { "lens": "telephoto", "zoom": 2.0 } },
  { "name": "feature_1", "type": "close_up", "description": "Highlight first key feature", "camera": { "lens": "standard", "zoom": 1.5 } },
  { "name": "feature_2", "type": "close_up", "description": "Highlight second key feature" },
  { "name": "in_use", "type": "medium", "description": "Product being used in context" },
  { "name": "reveal_pan", "type": "panning", "description": "Slow pan revealing the product from a new angle", "camera": { "movement": "pan_left" } },
  { "name": "final_hero", "type": "medium", "description": "Final beauty shot with branding" }
]
```

## Template: Tutorial / How-To (5–10 shots)

```json
[
  { "name": "intro_presenter", "type": "medium", "description": "Presenter introduces the topic (upper body)" },
  { "name": "overview_wide", "type": "wide", "description": "Show the full workspace / setup" },
  { "name": "step_1_hands", "type": "close_up", "description": "Close-up of hands doing step 1" },
  { "name": "step_1_result", "type": "medium", "description": "Show result of step 1" },
  { "name": "step_2_hands", "type": "close_up", "description": "Close-up of step 2 action" },
  { "name": "step_2_result", "type": "medium", "description": "Result of step 2" },
  { "name": "step_3_detail", "type": "extreme_close_up", "description": "Critical detail in step 3" },
  { "name": "final_result", "type": "medium", "description": "Show completed result" },
  { "name": "outro_presenter", "type": "medium", "description": "Presenter wraps up, call to action" }
]
```

## Template: Vlog / Day-in-Life (6–12 shots)

```json
[
  { "name": "morning_wide", "type": "establishing", "description": "Wide shot setting the scene (location, time of day)" },
  { "name": "activity_1", "type": "medium", "description": "First activity or location" },
  { "name": "b_roll_1", "type": "insert", "description": "Detail / texture / atmosphere B-roll" },
  { "name": "walking_track", "type": "tracking", "description": "Walking shot, moving through space", "camera": { "movement": "dolly_forward" } },
  { "name": "activity_2", "type": "medium", "description": "Second activity or location" },
  { "name": "reaction", "type": "close_up", "description": "Face / reaction shot" },
  { "name": "b_roll_2", "type": "cutaway", "description": "Environmental cutaway" },
  { "name": "activity_3", "type": "medium", "description": "Third activity" },
  { "name": "sunset_tilt", "type": "tilting", "description": "Tilt up to sky / sunset / closing visual" },
  { "name": "outro", "type": "medium", "description": "Sign-off to camera" }
]
```

## Template: Interview (3–5 shots)

```json
[
  { "name": "interviewee_medium", "type": "medium", "description": "Subject framed medium, slightly off-center" },
  { "name": "interviewee_close", "type": "close_up", "description": "Close-up for emotional moments" },
  { "name": "b_roll_context", "type": "wide", "description": "Contextual B-roll of subject's environment" },
  { "name": "detail_insert", "type": "insert", "description": "Hands, objects, or props they reference" },
  { "name": "two_shot", "type": "over_the_shoulder", "description": "Over-the-shoulder showing both people (if applicable)" }
]
```

## Template: Food / Cooking (6–9 shots)

```json
[
  { "name": "ingredients_overhead", "type": "high_angle", "description": "All ingredients laid out, overhead shot" },
  { "name": "prep_hands", "type": "close_up", "description": "Chopping / prep work close-up" },
  { "name": "cooking_medium", "type": "medium", "description": "Cooking action at the stove" },
  { "name": "sizzle_detail", "type": "extreme_close_up", "description": "Sizzle / steam / texture detail" },
  { "name": "plating", "type": "close_up", "description": "Plating the dish" },
  { "name": "final_dish_hero", "type": "medium", "description": "Final dish beauty shot" },
  { "name": "first_bite", "type": "close_up", "description": "First bite / taste reaction" }
]
```

## Template: Short Film / Narrative (8–15+ shots)

```json
[
  { "name": "establishing", "type": "establishing", "description": "Set the world — location, mood, time" },
  { "name": "character_intro", "type": "medium", "description": "Introduce the main character" },
  { "name": "detail_setup", "type": "insert", "description": "Object or detail that matters to the story" },
  { "name": "inciting_wide", "type": "wide", "description": "The event that changes things" },
  { "name": "reaction_close", "type": "close_up", "description": "Character's reaction" },
  { "name": "tension_low", "type": "low_angle", "description": "Low angle for dramatic tension" },
  { "name": "action_track", "type": "tracking", "description": "Follow the character in motion" },
  { "name": "confrontation", "type": "over_the_shoulder", "description": "Key dialogue or confrontation" },
  { "name": "climax_close", "type": "close_up", "description": "Climactic moment close-up" },
  { "name": "resolution", "type": "medium", "description": "Resolution of the conflict" },
  { "name": "final_wide", "type": "wide", "description": "Closing wide shot — new equilibrium" }
]
```

## Camera Movement Patterns

### Cinematic / Dramatic
- Slow `dolly_forward` into subject face → builds intensity
- Low angle + slow `tilt_up` → reveals power
- Slow `pan_left` or `pan_right` → reveals new information

### Energetic / Fast-paced
- Quick `tracking` shots following movement
- Rapid alternation between `close_up` and `wide`
- Handheld feel (shorter clips, more cuts)

### Calm / Elegant
- Static shots with long holds (3–5 seconds)
- Slow `panning` across scene
- Shallow depth of field (`telephoto` lens, low zoom)

## Planning Tips

1. **Always start with an establishing shot** — gives the viewer spatial context
2. **Vary shot types** — avoid 3+ consecutive medium shots; alternate wide/medium/close
3. **Plan B-roll** — at least 2 insert/cutaway shots per sequence for editing flexibility
4. **Match shot count to video length** — ~1 shot per 3–5 seconds of final video
5. **End strong** — close with a wide shot or a deliberate final image
6. **Consider audio** — some shots exist mainly to give space for narration or music
