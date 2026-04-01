# Stripe Checkout Rollout Summary (2026-03-31)

## Scope
Implemented and deployed the client-verify Stripe checkout flow improvements for Neox iOS, including UX cleanup and reliability hardening.

## What Changed

### iOS App (Neox)
- Removed model badge and `$` usage badge from chat toolbar.
- Added Stripe checkout launch path via chat tool and in-app checkout presentation fallback.
- Added deep-link handling (`neox://stripe/success?...`) plus foreground-resume verification path.
- Added success toast when credits are granted.
- Added auto-dismiss of checkout view on successful verification.
- Added client-side dedupe by Stripe `sessionId` to prevent duplicate credit grants.

### Relay (copilot-relay)
- Extended `POST /stripe/verify` to accept either:
  - `session_id`
  - `client_reference_id` (for foreground-resume verification)
- Added Stripe lookup by recent completed sessions for `client_reference_id` matching.
- Returned `sessionId` in verify responses for deterministic client-side dedupe.

## Commits

### Neox
- `af41fe0` — Stripe checkout UX: hide badges, add success toast, auto-close, and verify dedupe
- Pushed to `origin/main` (`973914c..af41fe0`)

### copilot-relay
- `cd0897a` — Stripe verify: support `client_reference_id` and return `sessionId`
- Pushed to `origin/main` (`d6be379..cd0897a`)

## Validation
- iOS build: **BUILD SUCCEEDED** on physical device target.
- Device deployment: installed and launched successfully via `devicectl`.
- Relay syntax check: passed (`node --check`).
- Relay E2E tests: passed after API expectation update.
- Stripe verification endpoint validated for both `session_id` and `client_reference_id` flows.
- User confirmed real-device behavior:
  - checkout opens
  - payment processed
  - returning to chat shows balance increase

## Known Notes
- Full automation of card entry/payment is not available via current device tooling; one final human-paid cycle is still the strongest runtime confirmation for auto-close + single-grant behavior in one pass.

## Recommended Next Check
1. Trigger one fresh checkout.
2. Complete payment.
3. Confirm:
   - checkout closes automatically,
   - success toast appears,
   - credits increase exactly once.
