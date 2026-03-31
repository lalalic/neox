# App Store Connect IAP Package (Consumables)

Bundle ID: `com.neox.app`  
Product type: **Consumable**  
Currency: USD

## Products

### 1) Starter Credits
- Product ID: `com.neox.credits.starter`
- Reference Name: `Starter Credits`
- Price Tier: `$4.99`
- Display Name (en-US): `Starter Credits`
- Description (en-US): `Quick top-up for light usage. Adds credits to your Neox balance for AI requests.`

### 2) Standard Credits
- Product ID: `com.neox.credits.standard`
- Reference Name: `Standard Credits`
- Price Tier: `$9.99`
- Display Name (en-US): `Standard Credits`
- Description (en-US): `Best value for regular usage. Adds credits to your Neox balance for AI requests.`

### 3) Pro Credits
- Product ID: `com.neox.credits.pro`
- Reference Name: `Pro Credits`
- Price Tier: `$29.99`
- Display Name (en-US): `Pro Credits`
- Description (en-US): `Large top-up for power users. Adds credits to your Neox balance for AI requests.`

---

## zh-Hans Localization (copy-ready)

### 1) Starter Credits
- Product ID: `com.neox.credits.starter`
- Display Name (zh-Hans): `入门额度包`
- Description (zh-Hans): `适合轻量使用的快速充值。用于补充 Neox 内 AI 请求所需额度。`

### 2) Standard Credits
- Product ID: `com.neox.credits.standard`
- Display Name (zh-Hans): `标准额度包`
- Description (zh-Hans): `适合日常使用的高性价比充值。用于补充 Neox 内 AI 请求所需额度。`

### 3) Pro Credits
- Product ID: `com.neox.credits.pro`
- Display Name (zh-Hans): `专业额度包`
- Description (zh-Hans): `适合高频用户的大额充值。用于补充 Neox 内 AI 请求所需额度。`

---

## Review Screenshot Guidance

Use one screenshot from the app showing:
- Settings screen with **Credits** section and **Buy Credits** entry
- Credits page with balance card and available packs

Name suggestion:
- `iap-credits-screen-en-us.png`

---

## Review Notes (copy-ready)

```
Neox offers consumable credit packs used to pay for AI model usage inside the app.

Products:
- com.neox.credits.starter (Starter Credits)
- com.neox.credits.standard (Standard Credits)
- com.neox.credits.pro (Pro Credits)

How to find purchase UI:
1) Open Neox
2) Tap Settings (gear icon)
3) Open Credits / Buy Credits
4) Select any credit pack

Consumable behavior:
- Purchased credits are added to local in-app balance immediately.
- Credits are consumed as AI requests are processed.
- Credits are non-refundable in-app and not restored across devices.
```

---

## Compliance / Behavior Checklist

- [ ] Product IDs exactly match app code (`PaymentManager.productIDs`)
- [ ] Consumable type selected for all 3 IAPs
- [ ] Prices match intended tiers: 4.99 / 9.99 / 29.99
- [ ] Localized display name and description provided (en-US minimum)
- [ ] Screenshot uploaded for each product
- [ ] Reviewer notes pasted
- [ ] In-app UI labels align with App Store metadata

---

## In-App Mapping (for sanity check)

Code mapping in `PaymentManager`:
- `com.neox.credits.starter` -> `$3.50` internal credit value
- `com.neox.credits.standard` -> `$7.50` internal credit value
- `com.neox.credits.pro` -> `$25.00` internal credit value

These internal values represent app credit budget, not App Store list price.

---

## Submission Flow

1. Create all 3 IAPs in App Store Connect with metadata above.
2. Attach each IAP to the app version for review.
3. Submit app version + IAPs together.
4. After approval, verify on device with sandbox + production storefront behavior.
