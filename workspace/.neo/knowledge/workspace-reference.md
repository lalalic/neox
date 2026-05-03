# Workspace Reference

## Purpose
- This file is a stable reference map for the Neo workspace.
- Use it when you need a quick reminder of what lives where before opening the full prompt or skill files.

## Package Identity
- Name: `neo`
- Version: `1.0.0`
- Description: `Neo: an AI citizen growing in the digital world`
- Layout: monorepo workspace with behavior under `.github/` and memory under `.neo/`

## Agent Index
- `main.agent.md` - primary assistant behavior
- `memory.agent.md` - memory report generation
- `review-project.agent.md` - project review
- `review-project-task-ready.agent.md` - task readiness review
- `wechat-router.agent.md` - route WeChat messages
- `wechat-answer-constructor.agent.md` - synthesize WeChat answers
- `wechat-channel.agent.md` - orchestrate WeChat channel responses

## Skill Index
- General assistance: `assist-user`, `morning-planning`
- Project creation: `make-app`, `site`
- Web and research: `web-agent`, `web-search`, `find-install-skills`, `notebooklm`
- Media and content: `marp-slides`, `mermaid-diagrams`, `remotion-templates`, `shot-planning`, `video-intents`, `youtube`, `find-bgm`, `free-bgm`, `social-media-auto`
- WeChat: `wechat-assistant`, `wechat-bridge`, `construct-wechat-response`
- Business and growth: `make-money`

## Onboarding Reference
- `.github/boarding.md` introduces Neo, highlights three flagship capabilities, asks the user's name, and stores profile details in `.neo/memory/user-profile.md`.

## Memory Reference
- `agents/neo.agent.md` - local `.neo` agent entrypoint
- `mission.md` - canonical identity and mission
- `memory.md` - general durable notes and quick index
- `memory/user-profile.md` - user profile and preferences
- `memory/topics/` - recurring topic memory
- `memory/projects/` - durable project and workspace memory
- `reports/` - generated session and periodic summaries

## Refresh When
- Agent files change
- Skill inventory changes
- Onboarding flow changes
- Memory contract changes
