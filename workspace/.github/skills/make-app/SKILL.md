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
Use the `create_task` tool:
```
create_task(appName: "MyApp", taskDescription: "A fitness tracker that...")
```

This will:
- Create a GitHub repo under neos-apps org
- Set up build secrets
- Create an issue with the task description
- Assign copilot-swe-agent to build it

### 3. Monitor Progress
The coding agent will:
- Read the task description
- Generate code (React Native / Expo)
- Create a PR when done
- Send progress notifications via push

Monitor via `report_progress` notifications.

### 4. Review & Merge
When the coding agent creates a PR:
- Review the changes
- Auto-merge triggers if configured
- Build queue notifies BullX desktop companion

### 5. Build & Install
After PR merge:
- BullX picks up the build job
- Builds the app locally on Mac
- Installs directly to user's iPhone via USB
- Push notification sent when complete

## Tips
- Keep task descriptions specific and actionable
- One feature per task works best
- The coding agent understands React Native, Expo, and iOS
- Free Apple ID allows 7-day dev certificates (auto-renewed by rebuild)
- For complex apps, break into multiple issues/PRs
