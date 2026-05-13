# Neox — User Stories (Settings)

## US-01: Select AI model
**As a** user, **I want to** choose which AI model powers the agent,
**so that** I can use the best model for my task.

## US-02: Manage providers (BYOK)
**As a** user, **I want to** add, edit, and remove custom OpenAI-compatible providers with API keys,
**so that** I can bring my own keys and access models from any provider.

## US-03: Top up credits
**As a** user, **I want to** see my balance and top up credits,
**so that** I can keep using the relay service.

## US-04: Manage plans
**As a** user, **I want to** create and run task plans,
**so that** the agent can execute multi-step workflows.

## US-05: Browse workspace files
**As a** user, **I want to** browse the agent's workspace directory,
**so that** I can inspect files the agent has created or modified.

## US-06: Configure channels
**As a** user, **I want to** enable WeChat or Discord channels,
**so that** the agent can be reached from those platforms.

## US-07: View about / version info
**As a** user, **I want to** see the app version, build number, and device ID,
**so that** I can report issues and verify I'm running the right version.

## US-08: Developer settings
**As a** user, **I want to** toggle dev server and debug options,
**so that** I can test against local infrastructure.

---

# Neox — User Stories (Remote Mac Neo via Relay)

> Neox is the phone-side counterpart to a Mac Neo install. These stories cover
> the on-the-go remote-access flows that ride on top of the relay's
> `/api/neo/*` proxy and Neo's persistent WS connection (see bullx US-46/47/48).

## US-09: Discover & pair with Mac Neo
**As a** Neox user, **I want to** discover my own Mac Neo install and pair
with it, **so that** my phone can later issue requests against it through the
relay.

**Acceptance criteria:**
1. A "Pair with Mac Neo" entry exists in Neox Settings.
2. The pairing flow shows the list of `deviceId`s owned by the signed-in relay
   account (relay returns the set keyed by bootstrap-token ownership / user).
3. Selecting a `deviceId` stores it locally as `pairedNeoDeviceId`; subsequent
   API calls (`POST /api/neo/*`) automatically scope to that device.
4. If only one Neo is registered for the user, auto-select on first launch.
5. Unpair button clears `pairedNeoDeviceId` and tears down any active SSE.
6. Offline indicator if the relay reports the paired Neo's WS as disconnected.

## US-10: Chat with my Mac Neo from the phone
**As a** Neox user, **I want to** open a chat with my paired Mac Neo and send
prompts from my phone, **so that** I can drive my agent while away from my
desk.

**Acceptance criteria:**
1. Chat tab uses Neo's `/api/chat/send` (bridged through `/api/neo/chat/send`)
   and streams assistant tokens via SSE on `/api/neo/sse/chat`.
2. The same conversation appears in Neo's project chat panel on the Mac (single
   source of truth — phone is a thin client, not a separate session).
3. Reconnect / resume: if the SSE drops, Neox re-subscribes and re-renders any
   messages buffered server-side since the last seen event id.
4. Network-error UI: distinguishes "phone offline" from "Neo offline" (latter
   surfaced when relay returns `503 neo offline`).
5. Tool-call events stream through and are shown as collapsed cards on the
   phone (no execution UI — execution always happens on the Mac).

## US-11: Answer Mac Neo's ask_questions from the phone
**As a** Neox user, **I want to** receive my Mac Neo's `ask_questions` prompts
on my phone and answer them, **so that** the agent never blocks just because
I'm not at my desk.

**Acceptance criteria:**
1. When Mac Neo is set to `askChannel = "neox"` (or `"auto"` and Neox is the
   highest-priority live subscriber), pending `ask_questions` calls are
   delivered to the paired Neox phone via SSE `event: ask_questions`.
2. Neox shows a foreground card / push-notification banner with the question
   and either a multiple-choice picker or a free-text field.
3. Submitting an answer calls `POST /api/neo/chat/answer-questions` with the
   `questionId` and value; the Mac Neo agent resumes the turn.
4. If multiple Neox phones are subscribed, only the first answer wins; the
   relay broadcasts an `ask_questions:answered` event to the rest so they can
   dismiss the banner.
5. If the phone is offline when the question fires, it is delivered on next
   reconnect (relay buffers the latest unanswered question per session).

## US-12: Push notifications for Neo events
**As a** Neox user, **I want to** receive push notifications for important Neo
events (new question, turn complete, error), **so that** I notice and respond
without keeping the app open.

**Acceptance criteria:**
1. APNs token is registered with the relay on first launch after pairing.
2. The relay forwards a push when the paired Neo emits any of: `ask_questions`,
   `session.idle` with new assistant content, `error`.
3. Notification payload deep-links into the relevant Neo session and (for
   `ask_questions`) opens the answer card directly.
4. Notifications honour iOS Focus modes / Do Not Disturb; the relay does not
   need to know about them (delivered by APNs).
5. User can disable push per-event-type from Neox Settings; the toggles are
   persisted in the relay account profile so they sync across re-installs.

