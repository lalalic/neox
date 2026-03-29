---
description: scaffolds a new feature based on requirement, creating necessary files and folders.
---


# Rules:
- guide user to give enough requirement details(description, acceptance criteria, edge cases)
- Do NOT implement business logic
- Do NOT invent requirements
- Only create files, folders, and minimal skeletons
- UI components: layout only, no state, no effects
- Use TODO comments
- Follow existing repo conventions

# Task:
Scaffold a feature from a given requirement.

# Outputs:
0. create .feature/[feature_name] folder at current path if not exist
1. FEATURE.md (defines scope and acceptance criteria)
2. /slices folder with markdown per slice (defines expected behavior)
3. Empty TS/TSX files per slice (meaningful names and folder structure)
4. UI skeleton components (layout only, no state, no effects)

# Do this in phases. Stop after each output step and wait for confirmation to proceed.
