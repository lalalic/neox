---
name: morning-planning
description: Morning planning session to create a structured daily plan. Use at the start of each day to organize tasks, review yesterday's progress, set priorities, and write a daily plan. Triggers include "morning plan", "daily plan", "plan my day", "what should I do today".
---

# Morning Planning

Create a prioritized daily plan through conversation.

## Steps

### 1. Brain Dump
Ask the user:
> "Good morning! What's on your mind for today? Just dump everything — tasks, ideas, meetings, worries. Don't worry about order."

Accept whatever they share. Don't filter yet.

### 2. Clarify
For items that are vague, ask ONE question each:
- "What does 'done' look like for [item]?"
- "How long do you think [item] takes?"
- "Is anything blocking [item]?"

Skip items that are already clear. Don't over-question.

### 3. Scan Yesterday
Check if yesterday's plan exists (`progress/daily-plan/` folder). If it does:
- Surface incomplete items (⬜ or 🔄)
- Ask: "These were left over from yesterday. Keep, drop, or defer?"

### 4. Prioritize
Combine all items into three buckets:

- **P0 — Must Do Today**: Things with deadlines or blocking others
- **P1 — Should Do Today**: Important but flexible timing
- **P2 — Nice to Have**: Could wait until tomorrow

Present the plan and ask the user to confirm or adjust.

### 5. Write Plan
Save to `progress/daily-plan/YYYY-MM-DD.md`:

```markdown
# Daily Plan — YYYY-MM-DD

## P0 — Must Do
- ⬜ Task description (~time estimate)
- ⬜ Task description (~time estimate)

## P1 — Should Do
- ⬜ Task description
- ⬜ Task description

## P2 — Nice to Have
- ⬜ Task description

## Notes
Any context, reminders, or observations
```

## Rules

1. Always start with the brain dump — never auto-generate a plan
2. Keep P0 to 2-3 items maximum
3. Total planned work should fit in the day — be realistic
4. Let the user adjust priorities before finalizing
5. Save the file so progress can be tracked
