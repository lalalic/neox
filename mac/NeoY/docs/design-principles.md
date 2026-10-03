# NeoY V2 Design Principles

This document is the canonical architecture contract for work under `mac/NeoY`.
README files may summarize it, and `AGENTS.md` may translate it into execution
rules, but those files must not maintain independent copies of these principles.

## Authority

NeoY is the authenticated external MCP gateway and native macOS capability host.
Its architecture exists to preserve clear capability ownership, a small stable
agent surface, and explicit boundaries between native privilege, product
lifecycle, platform mechanics, and deployment infrastructure.

When an implementation choice conflicts with a principle below, the principle is
the default. A deliberate exception must be documented in the task/PR with the
specific principle, reason, and evidence that the exception is necessary.

### Core ownership contract

NeoY bundles the upstream MacBridge runtime and federates it internally. The
bundled provider owns generic shell execution, background jobs, filesystem
operations, PTY sessions, and read-only Codex thread access. NeoY does not keep
Swift implementations or compatibility stacks for those primitives. NeoY owns
the signed host process, authentication and authorization, remote exposure,
federation, native TCC/device capabilities, cluster routing, lifecycle, and the
public MCP facade. `apply_patch` remains the one deliberate NeoY-native core
adapter because its current direct contract is working and independently
authorized.

## Principles

### 1. Migrate capabilities, not tool surfaces

Preserve the capability a user or agent needs. Do not mechanically reproduce a
legacy MacBridge/MCP tool inventory just because an older system exposed it that
way.

A migration should first ask what stable intent or capability must survive, then
choose the smallest current contract that provides it.

### 2. Keep the external MCP surface small; keep internal services rich

NeoY's public surface should be compact, stable, typed, and self-describing.
Internal services may expose richer primitives to their owning runtime, but one
internal primitive does not imply one new public NeoY tool.

Prefer a small number of intent-oriented boundaries over a broad RPC mirror of
implementation details.

### 3. Expose user intent, not low-level primitives

Agent-facing contracts should describe useful outcomes and stable typed inputs.
Filesystem layout, process details, DOM selectors, transport retries, URL
construction, and other mechanics stay behind the component that owns them.

Low-level primitives remain appropriate only when the primitive itself is the
intended capability, such as an explicit shell or filesystem Core contract.

### 4. One authenticated external trust boundary

NeoY is the normal authenticated external gateway. Trusted local providers behind
NeoY should normally bind to loopback or another trusted local boundary rather
than each creating a parallel public authentication surface.

Do not expose an unauthenticated local provider directly to the Internet merely
because NeoY can reach it.

### 5. Native only when the capability must be native

Put a capability in NeoY's native process when it depends on the signed app
identity, macOS TCC, Accessibility, Screen Recording, direct local device access,
menu-bar/app lifecycle, or another genuinely process-local responsibility.

Generic workflow engines, browser platforms, tutoring, posting, event services,
and similar product/runtime logic should not move into NeoY merely for
convenience.

### 6. Federate; do not duplicate

If an existing service or runtime already owns a capability, keep that owner as
the source of truth and federate it through NeoY.

Provider registration/discovery failure must be isolated. Optional providers must
not make NeoY itself fail to launch. Bundled Core runtime dependencies may be
version-pinned deployment dependencies without becoming duplicated Swift
implementations.

For this migration, the Architecture Lens answers are explicit: generic
execution/filesystem/PTY/job/Codex access does not require NeoY's process or
TCC, and already has an upstream owner, so NeoY federates it; the exposed names
are the provider's MCP contracts rather than a second Swift command grammar; no
new public trust boundary is created; cluster remains NeoY-owned routing; and
provider submission/completion semantics are not simulated by NeoY.

### 7. Products own business lifecycle; platforms own UI mechanics

Product runtimes own durable business identity and workflow state, such as
`project_id`, `thread_id`, child/user IDs, correlation IDs, and explicit
business lifecycle.

Browser Workspace or another platform owner owns browser sessions, URLs, DOM
selectors, tab grouping, target reuse, Chrome state, and site-specific submission
mechanics. Do not persist platform identity as product truth when a stable
business identity exists.

### 8. Submission is not completion; deliver results explicitly

A synchronous ingress that starts browser/LLM/remote work should return after the
downstream system has accepted the submission. Do not keep the request open while
polling UI state for final completion.

Final results should arrive through an explicit typed delivery mechanism: a
result tool, event, callback, or equivalent contract keyed by stable correlation
identity. Prefer active delivery over scraping a result from DOM text.

### 9. PM2/deployment infrastructure is not a Core architecture dependency

PM2, launch scripts, tunnels, installers, package launchers, and service managers
are deployment infrastructure. They may supervise NeoY or related processes, but
they must not leak into the Core public capability model or become required
architecture dependencies of Core execution.

Core behavior must remain understandable independently of the chosen deployment
supervisor.

## Architecture Lens

For every NeoY feature or material change, planning must answer only the questions
that are relevant to that task, but it must not skip a relevant question.

1. **Native necessity** — Does this capability truly require NeoY's process,
   TCC/native privilege, signed identity, or device-local lifecycle? If not, why
   is it in NeoY?
2. **Existing owner** — Does an existing service/runtime already own this
   capability? If yes, why are we not federating it?
3. **Intent boundary** — Is the public contract expressing user/agent intent, or
   leaking internal primitives and transport mechanics?
4. **Surface growth** — Does this add a public MCP tool or public contract? If so,
   why can the need not be satisfied through an existing stable surface?
5. **Trust boundary** — Does this create another externally reachable auth/trust
   boundary? If so, why is one NeoY boundary insufficient?
6. **Business vs platform ownership** — Are browser/UI/platform mechanics leaking
   into product or gateway code? Are we persisting stable business identity rather
   than URLs, DOM selectors, target IDs, or other UI identity?
7. **Lifecycle semantics** — Is submission acknowledgement being confused with
   final completion? Where is the explicit result-delivery contract?
8. **Deployment leakage** — Is PM2, a launcher, tunnel, installer, or process
   supervisor becoming part of the Core capability contract?
9. **Migration semantics** — Are we preserving the capability, or mechanically
   copying a legacy tool surface?

The plan should record the applicable answers before implementation. The review
should re-check those answers against the actual diff and flag any contradiction.

## Planning and review contract

For work under `mac/NeoY`:

- planning must cite this document and materialize the relevant Architecture Lens
  answers into the task/plan;
- implementation must follow those answers unless the task records a deliberate,
  evidenced exception;
- review must verify both implementation correctness and applicable principle
  compliance;
- shared Planner/Reviewer agents should consume this repository context rather
  than duplicating these principles into their own prompts.

The principles are project context, not boilerplate to copy into every Task.
Only the task-relevant Architecture Lens should be materialized.

## Quick decision rule

```text
Does it require NeoY's process, TCC/native privilege, signed identity,
or device-local lifecycle?
  yes -> native NeoY capability may be appropriate
  no  -> keep capability with its product/runtime owner and federate through NeoY
```

Before adding a new public tool, apply the same test again at the contract level:
can the user intent be expressed through an existing stable surface instead?
