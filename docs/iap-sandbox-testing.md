# IAP Sandbox Testing Guide

This project uses StoreKit 2 consumables:

- `com.neox.credits.starter` ($4.99)
- `com.neox.credits.standard` ($9.99)
- `com.neox.credits.pro` ($29.99)

## 1) Local StoreKit testing in Xcode (no App Store Connect required)

1. Open `Neox.xcodeproj` in Xcode.
2. Edit Scheme → Run → Options.
3. Set **StoreKit Configuration** to `Neox/Config/Neox.storekit`.
4. Build and run app.
5. In app: Settings → Credits → Buy Credits.
6. Confirm products load and purchase flow updates local balance.

## 2) App Store Connect sandbox testing (real sandbox)

1. In App Store Connect, open app `com.neox.app`.
2. Create 3 **In-App Purchases** (Consumable) with exact IDs above.
3. Ensure each IAP is in "Ready to Submit" or approved state for sandbox visibility.
4. In App Store Connect Users and Access → Sandbox, create a sandbox tester account.
5. On iPhone, sign out of App Store test account if needed.
6. Run debug build from Xcode on device.
7. Trigger purchase in app; sign in with sandbox tester when prompted.

## 3) Expected app behavior

- Credits screen should stop showing "Loading products..." and list 3 packs.
- On successful purchase, `PaymentManager` adds credits via `UsageTracker.addCredits`.
- New balance appears immediately in Credits section and low-balance banner clears.

## 4) Troubleshooting

- Products never load:
  - Verify product IDs match exactly.
  - Verify bundle ID is `com.neox.app`.
  - Wait up to 15–30 minutes after creating IAPs in App Store Connect.
- Purchase dialog does not appear:
  - Ensure StoreKit config is attached to scheme for local testing.
  - Ensure network is available for sandbox testing.
- Balance not updated:
  - Check app logs for transaction verification failure.
  - Confirm `PaymentManager.creditValues` contains the product ID.
