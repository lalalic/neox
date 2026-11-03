# Neo Mobile review notifications — Apple APNs

**Owner:** Neo Mobile owns pending reviews and feedback retries. This provider
stores **only APNs device tokens**, never review sessions, comments, decisions or
an inbox. It federates through Neo Master's authenticated MCP gateway.

After `markcut.preview` returns the immutable `contentHash`, the requesting
ChatGPT thread or worker invokes `mcp.neox-apns` with command
`review.push.notify` and args:

```json
{
  "id": "<unique review request UUID>",
  "contentHash": "<64 lowercase SHA-256 hex characters>",
  "revisionId": "<immutable revision ID>",
  "title": "<video review title>",
  "ownerCallbackTool": "chatgpt",
  "ownerThreadId": "<existing originating ChatGPT thread ID>"
}
```

The iPhone registers its current token with the same authenticated Master using
`mcp.neox-apns` → `review.push.register`. The app decodes the notification,
adds a request to its local Inbox (or imports delivered notifications on next
launch), and returns feedback to the original owner. Its own local dedup prevents
old alert retries from recreating removed or completed requests.

APNs `200` means **Apple accepted the push**, not that the user saw it, nor that
feedback was processed. Alert delivery is best-effort, and APNs can replace or
expire notifications while a phone is offline. Do not infer a completed review
from a push submission. To support devices without APNs, the existing phone MCP
`review.request` works while the app is reachable.

For deployment, register `NeoxAPNs/mcp.mjs` as the `neox-apns` stdio provider in
NeoY and enable its remote provider exposure. Set the configuration and key in
Neo Master's `~/Library/Application Support/NeoY/apns/` (directory `0700`,
files `0600`); never commit APNs keys or device tokens. Run
`node --test NeoxAPNs/apns.test.mjs` to verify request validation, JWT signing,
and the mocked APNs contract. The owner callback uses authenticated Neo MCP,
not a separate public service.
