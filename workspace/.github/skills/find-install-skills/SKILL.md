---
name: find-install-skills
description: Discover and install new skills from the ClawHub registry (clawhub.ai). Use when the user wants to find a skill, add a new capability, browse available skills, or extend what the agent can do.
---

# Find & Install Skills

Search the ClawHub skill registry (clawhub.ai) to discover and install new capabilities.

## Browse Skills

```
web-agent navigate url=https://clawhub.ai
web-agent snapshot
# Browse featured and popular skills
```

## Search for a Skill

```
web-agent navigate url=https://clawhub.ai/search?q=YOUR+SEARCH+TERM
web-agent snapshot
# Read search results
# Click on a skill to see details
web-agent click ref=rN
web-agent snapshot
```

## Evaluate a Skill

Before installing, check:
1. **Description** — does it match what you need?
2. **Downloads/Stars** — popular skills are usually reliable
3. **Last Updated** — recent updates mean active maintenance
4. **SKILL.md content** — read the instructions to understand what it does

```
# On a skill page, read the full description
web-agent snapshot
# Look for SKILL.md or documentation sections
```

## Install a Skill

Skills are markdown files placed in `.github/skills/` folder. To install:

1. Read the skill's SKILL.md content from ClawHub
2. Create the skill folder: `.github/skills/SKILL-NAME/`
3. Save the SKILL.md file in that folder

The skill will be automatically discovered and available in future sessions.

## Skill Format

Every skill has a `SKILL.md` file with:
- **YAML frontmatter**: name, description
- **Body**: instructions the agent follows when the skill is triggered

```markdown
---
name: my-skill
description: What this skill does and when to use it
---

# Skill Title

Instructions for how to use this skill...
```

## Tips

1. Search by what you want to do, not by tool name
2. Read the SKILL.md before installing — understand what it does
3. Skills are just instruction files — they don't install software
4. You can modify installed skills to fit your needs
