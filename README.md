---
name: neox
description: iOS AI agent app — chat, browser, camera, tasks, all backed by GitHub Copilot CLI via relay
---

# Neox

An iOS app that turns your iPhone into an AI-powered agent. Talk to it, point your camera, let it operate websites, manage code, and automate tasks.

**Backend:** GitHub Copilot CLI via [copilot-ios](../copilot-ios) SDK through [copilot-relay](../copilot-relay)

## Features

- Chat with streaming responses, voice I/O, multi-modal input
- Agent-operated browser (WebKitAgent)
- AI-directed camera (CameraKit)
- Background task queue
- Stripe subscription + IAP
- APNs push notifications for build completions

## Build

```bash
# Generate Xcode project
xcodegen generate
# Build for simulator
xcodebuild -scheme Neox -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

## Docs

| Doc | Description |
|-----|-------------|
| [Product Spec](.github/product-spec.md) | Full feature spec and architecture |
| [Coding Agent Pipeline](docs/coding-agent-project-delivery-design-v2.md) | Two-tier agent architecture for project delivery |
| [Remote Project Dev](docs/2026-04-02-remote-project-dev-design.md) | Phone → GitHub → TestFlight pipeline |
| [Payment & Usage](docs/design-payment-usage.md) | Stripe + IAP design |
| [Lazy Attachment](docs/design-lazy-attachment.md) | Deferred media upload design |
| [Plan Management](docs/design-plan-management.md) | Subscription plan management |
| [IAP Sandbox Testing](docs/iap-sandbox-testing.md) | App Store sandbox test guide |
| [IAP ASC Package](docs/iap-app-store-connect-package.md) | App Store Connect integration |
| [Stripe Rollout](docs/stripe-checkout-rollout-summary-2026-03-31.md) | Stripe checkout migration summary |
| [Chat View Tests](docs/test-plan-chat-view.md) | Chat view test plan |
