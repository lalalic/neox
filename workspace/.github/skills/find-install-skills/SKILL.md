---
name: find-install-skills
description: Discover and install new skills. Use when the user wants to find a skill, add a capability, or browse available skills.
---

# Find & Install Skills

Skills are SKILL.md instruction files in `.github/skills/<name>/SKILL.md`.

## Step 1: Check what's already installed

```
read_file .github/skills/
```

If a matching skill already exists, tell the user — no need to install.

## Step 2: Search ClawHub registry

```
web-agent navigate https://clawhub.ai/search?q=YOUR+SEARCH+TERM
web-agent snapshot
```

Read the skill's SKILL.md content from the result page.

## Step 3: Install

Create `.github/skills/<name>/SKILL.md` with the YAML frontmatter + instructions.

```markdown
---
name: my-skill
description: What this skill does
---

Instructions...
```

The skill is automatically available in the next session.
