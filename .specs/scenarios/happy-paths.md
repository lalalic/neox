# Happy Paths — Neox Settings

## HP-01: Browse settings and verify layout (`neox-settings-layout`)
**Covers:** US-01, US-02, US-03, US-04, US-05, US-06, US-07, US-08

1. **Given** the app is on the main chat screen
2. **When** the user taps the Settings gear icon
3. **Then** the Settings sheet opens with "Settings" navigation title
4. **Then** the first section is "Agent Profile" with Model row, Agent Profile link, and Device ID
5. **When** the user scrolls down
6. **Then** they see "Providers" section with provider list
7. **Then** they see "Top Up" section with balance info
8. **Then** they see "Plans" section
9. **Then** they see "Workspace" section with File Explorer
10. **Then** they see "Channel" section with WeChat and Discord toggles
11. **When** the user scrolls to the bottom
12. **Then** the last visible sections are Developer (debug only) and About
13. **Then** About section shows version and build info
14. **When** the user taps Done
15. **Then** the settings sheet dismisses

**Exit criteria:** All settings sections are visible in the correct order. No crashes.

## HP-02: Add provider and select its model (`neox-add-provider`)
**Covers:** US-01, US-02

1. **Given** the user opens Settings
2. **When** they scroll to the Providers section
3. **And** they tap "Add Provider"
4. **Then** the add-provider form appears
5. **When** they enter a provider name, base URL, and API key
6. **And** they save the provider
7. **Then** the new provider appears in the Providers list
8. **When** they tap the Model row in Agent Profile
9. **Then** the new provider's models appear in the model picker
10. **When** they select a model from the new provider
11. **Then** the Agent Profile shows the selected model name

**Exit criteria:** Custom provider added, its model selectable.
