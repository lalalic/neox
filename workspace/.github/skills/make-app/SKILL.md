---
name: make-app
description: Guide the agent through the full app creation lifecycle on Neox — from idea to running app on user's phone. Covers project scaffolding, coding agent delegation, build, and install.
---

# How to Make an App

Create a working app from an idea, entirely from the phone.

## Workflow

### 1. Clarify the Idea
Ask the user:
- What does the app do? (one sentence)
- Who is it for?
- Any specific features? (camera, maps, payments, etc.)

### 2. Create the Project
Use the relay MCP tool `create_task`:
- `appName`: short name for the app
- `taskDescription`: detailed description of what to build

The relay server will:
- Create a GitHub repo under neox-apps org
- Set up build secrets
- Create an issue with the task description
- Assign a coding agent to build it

### 3. Monitor Progress
The coding agent will work on the repo and send progress updates via push notifications to your phone. You'll receive messages as the agent works.

### 4. Review & Merge
When the coding agent creates a PR:
- You'll be notified
- Review the changes if needed
- Auto-merge triggers when configured

### 5. Build & Install
After PR merge, if you have a Mac paired via BullX:
- BullX picks up the build job automatically
- Builds the app on your Mac
- Installs directly to your iPhone via USB
- Push notification sent when complete

If no Mac paired, the relay can trigger a cloud build via EAS.

## Tips
- Keep task descriptions specific and actionable
- One feature per task works best
- The coding agent understands React Native, Expo, and iOS
- Free Apple ID allows 7-day dev certificates (auto-renewed by rebuild)
- For complex apps, break into multiple issues/PRs
