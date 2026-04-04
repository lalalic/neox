# App Store Connect IAP Package (Consumable)

Bundle ID: `com.neox.app`  
Product type: **Consumable**  
Currency: USD

## Product

### Top Up Credits
- Product ID: `com.neox.credits.topup`
- Reference Name: `Top Up Credits`
- Price Tier: `$9.99`
- Display Name (en-US): `Top Up Credits`
- Description (en-US): `Adds $7.50 in credits to your Neox balance for AI requests.`

---

## zh-Hans Localization

### Top Up Credits
- Product ID: `com.neox.credits.topup`
- Display Name (zh-Hans): `充值额度`
- Description (zh-Hans): `为 Neox 账户充值 $7.50 额度，用于 AI 请求。`

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

### Review Notes (zh-Hans, copy-ready)

```
Neox 提供一次性消耗型额度包，用于支付应用内 AI 模型调用。

产品列表：
- com.neox.credits.starter（入门额度包）
- com.neox.credits.standard（标准额度包）
- com.neox.credits.pro（专业额度包）

购买入口：
1）打开 Neox
2）点击设置（齿轮图标）
3）进入 Credits / Buy Credits
4）选择任意额度包完成购买

消耗型行为说明：
- 购买成功后，额度会立即加入应用内余额。
- AI 请求执行时会按用量扣减额度。
- 额度为消耗型，不跨设备恢复。
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
