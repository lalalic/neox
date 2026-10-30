# Interactive OAuth Access-Token Renewal

## Objective

Allow a user-authorized interactive Z.ai client to renew a short-lived Neo MCP access token by presenting that same unexpired access token. Do not distribute the Neo operator credential or a long-lived refresh token to Z.ai.

## Architectural boundaries

- **Native necessity / owner:** NeoY is the existing OAuth authorization server and authenticated external gateway. Token rotation, revocation, persistence, and validation belong here, not inside a browser extension, Agents Relay, or an independent service.
- **New surface:** One authenticated OAuth HTTP route, `POST /token/renew`. No additional MCP tool or capability. The ordinary `/mcp` bearer gate stays unchanged.
- **Client identity:** Eligibility is restricted to access tokens issued to the registered client with the explicit `Z.ai interactive` label. Registration alone does **not** grant authority: a Neo operator must still complete the existing OAuth consent for the initial token. This label is a practical issuance selector, not proof of website or browser identity.
- **Session bounds:** Access lifetime remains 3600 seconds; the first issuance sets a fixed absolute session deadline of 8 hours. Each renewal rotates the token, immediately invalidates the previous token, and caps the new expiration at that initial deadline.
- **No persistent refresh secret:** Interactive issuance returns no 30-day OAuth refresh token, and does not store one. Standard OAuth clients retain their existing refresh behavior and are ineligible for access-token renewal.
- **Trust:** Browser Referer, Origin, Cookie, cloud IP, and Z.ai tab IDs are **not** credential proofs. Only a valid, unexpired, explicitly authorized bearer token can call this route. The Core operator token is forbidden.
- **Delivery:** A renewal returns JSON with the new token, `expires_in`, and `session_expires_in`, and `Cache-Control: no-store`. The agent should renew proactively within its existing chat while still active. The route does not create background jobs or guarantee an unattended agent.
- **Failure:** Expired, revoked, rotated, noninteractive, or over-deadline tokens fail with HTTP 401. The user then issues a fresh one-hour token on the trusted Neo Master.
- **Deployment:** Native Swift behavior; deploy via the canonical `mac/NeoY/install-local.sh` once, not an ad-hoc process restart.

## Contract

With an eligible unexpired OAuth access token:

```http
POST /token/renew HTTP/1.1
Authorization: Bearer <current-short-lived-token>
Accept: application/json
```

The returned `access_token` **replaces** the supplied one. Do not log or write it into a shared file. Call again only while the current token is active and before the fixed session deadline.

## Verification

NeoYOAuthTests verifies initial PKCE authorization, absence of long-lived refresh tokens, valid renewal and rotation, old-token replay failure, operator-token denial, normal OAuth client denial, and a persisted session deadline test. Run the full NeoY test suite and verify real HTTPS authorization, renewal, and rotated-token access after the canonical native deployment.
