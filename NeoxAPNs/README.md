# Neo Mobile review delivery — Neo Master APNs

**Two separate contracts:**

1. **Preview request delivery:** Markcut MCP and Codex CLI publish immutable previews, then submit the same metadata to Neo Master's durable `review.push.notify`. Master stores the request in its private `~/Library/Application Support/NeoY/apns/reviews.json`; Apple APNs receives only the UUID as `neoReviewRequestId`. iPhone does **not** need to expose MCP or be online. App foreground/notification taps trigger authenticated `review.push.pending` to recover complete requests.
2. **Review result delivery:** Neo Mobile user opens the compiled video in Review Inbox and submits `approved` or `changes_requested`. With caller-supplied Event Template, phone fills fixed `data.interactive` review fields and publishes `task.interactive_decision` through Events MCP. Then `review.push.complete` retires the durable request. Bus ACK is transport acceptance only; Relay Graph owns Task continuation.

**Unified Preview ingress:** `NeoxAPNs/review-cli.mjs notify` reads one JSON review request from stdin and returns a `{stored:true,requestId,accepted:<APNs status>}` JSON receipt. This is the local, Neo-Master-only integration used by the Markcut hosted compiler in both MCP and CLI. Neo's authenticated `mcp.neox-apns` facade exposes the same `review.push.notify` plus `review.push.register`, `review.push.pending`, `review.push.complete` and `review.push.status`. The private key/device token remain in the 0700 APNs data directory. Do not create a new public listener or send a bearer token to an arbitrary phone address.

**Important:** Master persistence and APNs acceptance are separate. A failed/expired APNs push does not discard the pending review; the phone retrieves it on the next authenticated foreground sync. Push payload contains only a request UUID, never event templates or credentials. A default ChatGPT Text-mode Preview with no owner thread is mirrored to the phone for **viewing only**; only explicit `task.interactive_decision` Event templates authorize phone result submission. Legacy `markcut.review.submitted` templates are rejected.

Run `node --test NeoxAPNs/apns.test.mjs` and a real device review to verify the two contracts independently. APNs send uses the existing Apple credentials/config and registered devices under NeoY/apns.
