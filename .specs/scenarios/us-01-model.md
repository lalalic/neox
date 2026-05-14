# US-01: Select AI model

## S-01.1: View current model
**Given** the user opens Settings
**When** they look at the Agent Profile section
**Then** they see a "Model" row showing the currently selected model name

## S-01.2: Open model picker
**Given** the user opens Settings
**When** they tap the "Model" row
**Then** a ModelPickerView appears showing provider groups and their models

## S-01.3: Change model
**Given** the user is on the model picker
**When** they select a different model
**Then** the selection is saved and the Agent Profile row updates to show the new model name

## S-01.4: Picker reflects provider's enabled-models toggles immediately
**Given** the user has a provider (e.g. Relay) with multiple models enabled
**When** they open that provider, toggle one model off, and return to the model picker (without relaunching the app)
**Then** the picker shows only the still-enabled models for that provider
**And** if they re-enable the model, the picker shows it again without relaunch

> Regression scenario for the picker live-sync bug fixed in `copilot-ios@5a76122`
> (shared `NeoxCore.BaseCoordinator`). Affects Intento and Neox equally.

