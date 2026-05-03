# Neo Workspace

## Purpose
- Package name: `neo`
- Version: `1.0.0`
- Description: `Neo: an AI citizen growing in the digital world`
- Shape: monorepo workspace focused on prompts, skills, onboarding, and long-term memory

## Top-Level Layout
- `.github/agents/` contains the main assistant, memory, review, and WeChat orchestration agents.
- `.github/skills/` contains reusable capability modules for app building, planning, web work, media work, and platform integrations.
- `.github/boarding.md` defines the first-run onboarding flow.
- `.neo/reports/` already contains daily, weekly, monthly, yearly, and session report buckets.
- `.neo/sync-templates.sh` syncs template directories to mapped GitHub repositories.

## Agent Surface
- 7 agent files are currently present.
- Core roles:
  - `main.agent.md`: primary assistant behavior
  - `memory.agent.md`: report generation
  - `review-project*.agent.md`: review gates
  - `wechat-*.agent.md`: routing, answer construction, and channel orchestration

## Skill Surface
- 21 skills are currently present.
- Key skills include:
  - `assist-user`
  - `make-app`
  - `morning-planning`
  - `web-agent`
  - `web-search`
  - `wechat-assistant`
  - `wechat-bridge`
  - `social-media-auto`
  - `remotion-templates`
  - `notebooklm`

## Durable Workspace Observations
- This workspace is behavior-first: `.github/` defines what Neo can do and how Neo should behave.
- `.neo/` should hold durable state, memory, and history rather than transient prompt fragments.
- The workspace already expected structured memory under `.neo/memory/`, but that structure had not been seeded yet.
- Onboarding emphasizes three flagship capabilities: building apps, browsing the web to do tasks, and planning the day.
- Durable repo-level directions should also be captured in `.neo/` when they affect testing strategy or major migrations.

## Refresh Triggers
- Add, remove, or rename agents or skills.
- Change onboarding flow or core capability framing.
- Change package identity or workspace purpose.
- Change the `.neo/` memory contract.
