# Copilot Instructions

This is an Expo (React Native) app built with TypeScript.

## Stack
- Expo SDK 55+
- React Native 0.83+
- TypeScript 5.9+
- Managed workflow (no ejecting)

## Rules
- All code must be TypeScript (`.tsx` for components, `.ts` for utilities)
- Run `npx tsc --noEmit` before every commit
- Functional components with hooks only — no class components
- Keep files small: one component per file, max ~200 lines
- Name files by their component: `TaskList.tsx`, `AddTaskModal.tsx`
- Use StyleSheet.create for styles — no external CSS libraries
- State: React hooks (useState, useReducer, useContext). No Redux unless spec requires it
- Target iOS (iPhone) as primary platform

## Project Structure
- `App.tsx` — entry point
- `app/` — Expo Router pages (file-based routing)
- `components/` — reusable components
- `assets/` — images, fonts

## Naming Conventions
- **NEVER** prefix files or folders with `private`, `internal`, or similar prefixes
- Use descriptive, standard names: `components/TaskList.tsx`, `utils/formatDate.ts`, `hooks/useTimer.ts`
- Folders: `app/`, `components/`, `utils/`, `hooks/`, `types/`, `assets/`
- No underscore prefixes (`_components/`), no `src/` wrapper (Expo convention)


## Validation
- Run `npx tsc --noEmit` before commits to catch type errors

## Error Recovery
- **Type error:** Fix it. Don't skip or use `any` unless truly unavoidable.
- **Missing dependency:** Install with `npx expo install <package>` (not npm/yarn directly)
