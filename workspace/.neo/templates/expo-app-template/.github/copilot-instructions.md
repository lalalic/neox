# Copilot Instructions

This is an Expo (React Native) app built with TypeScript.

## Stack
- Expo SDK 55+
- React Native 0.83+
- TypeScript 5.9+
- Managed workflow (no ejecting)

## Rules
- All code must be TypeScript
- Run `npx tsc --noEmit` before committing to catch type errors
- Keep code simple and working — no over-engineering
- Use functional components with hooks
- Use StyleSheet.create for styles
- Target iOS (iPhone) as primary platform

## Project Structure
- `App.tsx` — entry point
- `app/` — Expo Router pages (if using file-based routing)
- `components/` — reusable components
- `assets/` — images, fonts

## MCP Tools
This project has a relay MCP server configured. Use these tools:
- `send_response(message)` — send chat messages to the user's phone
- `report_progress(title, message, status)` — send structured milestone notifications (status: info/success/warning/error)
- `report_usage(model, totalTokens)` — report token consumption (call once at session end)

Do NOT ask the user questions. Work autonomously and make best-judgment decisions.
