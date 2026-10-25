# Auto Vlog mobile / Master interface proposal (Jobs 508 and 509)

Status: **pending agreement** with Job 509 Task 233. This document is a
proposal, not an implemented public endpoint or an assertion of integration.

The iPhone stores private-draft candidate-selection intent locally and binds
it to the existing Home-screen-selected Neo Master name. It does not invoke
automatic media discovery until the Master contract is negotiated. The current
UI must report pending support, even when consent is enabled.

Proposed existing authenticated Core gateway operation (exact tool name and
wire schema to be decided by Job 509):

- Request: selected Master identity, opt-in boolean, lookbackDays (1-30),
  maxCandidates (1-50), privateDraftOnly=true, gpsDisclosure=false and
  publicationAllowed=false. Identity must be verified by the existing gateway,
  not trusted solely from a phone-supplied label.
- Response: accepted consent revision, Master identity, availability
  (available/deferred/offline/unsupported), reason, last observation time.
- Manual submission status: stable submissionId, state accepted/queued,
  processing/review/finished/failed only from the authoritative Master
  lifecycle, and optional episode/job/task IDs. The existing schema-v1 iCloud
  manifest remains unchanged. No producer completion from transfer success.
- Reconnect: idempotent replay of the same consent revision and submissionId,
  with read-only status query; no duplicate Episode allocation.

Neither mode permits public publication or GPS disclosure through this consent.
Auto media search/vision/export stay on the existing Neox media MCP and local
Wi-Fi ranged /files service. No second phone server, public upload endpoint,
or public preference MCP tool is proposed.

**Integration blocker:** Task 233 is RUNNING and its durable intake objective
does not define a finished consent/availability wire schema. Before activating
Auto Vlog, Job 509 must approve the contract and implement authoritative
Master availability/status plus authenticated consent handoff. Job 508 must
then implement a matching client and add end-to-end tests.
