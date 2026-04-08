---
name: find-install-skills
description: Discover and install new skills. Use when the user wants to find a skill, add a capability, or browse available skills.
---

# Find & Install Skills

Skills are SKILL.md instruction files in `.github/skills/<name>/SKILL.md`.

## Step 1: Check what's already installed

```
ls .github/skills/
```

If a matching skill already exists, tell the user — no need to install.

## Step 2: Search ClawHub registry

```
web-agent navigate https://clawhub.ai/search?q=YOUR+SEARCH+TERM
web-agent snapshot
```

Read the skill's SKILL.md content from the result page.

## Step 3: Install to device workspace

Use `run_in_terminal` to create the skill folder and file:

```
mkdir -p .github/skills/<name>
cat > .github/skills/<name>/SKILL.md << 'EOF'
---
name: my-skill
description: What this skill does
---

Instructions...
EOF
```

The skill is available after the next session reconnect.
