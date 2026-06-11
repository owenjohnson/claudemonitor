# ADR-005: Anthropic (Claude) usage plugin

**Date:** 2026-06-11
**Status:** Proposed (for the successor repository)
**Deciders:** Owen Johnson, Claude

---

## Context

ADR-004 defines the plugin framework (protocol, normalized domain model,
vault-backed secrets). This ADR specifies the Anthropic plugin — a direct port
of the mechanism proven in this repo (see `docs/REBUILD-SPEC.md` §2–3, which
this ADR supersedes as the normative reference for the new repo).

Anthropic exposes **no usage API**. Subscription utilization is only
observable via rate-limit response headers on inference calls — undocumented
behavior that has nonetheless been stable across this repo's lifetime.

## Decision

### Credentials

| | |
|---|---|
| Vault keys (`anthropic/<account>/…`) | `oauth_token` (immutable — no refresh flow) |
| Acquisition | User runs `claude setup-token` (interactive browser OAuth), pastes result into `<app> service add anthropic` / `<app> vault set` |
| Token shape | `sk-ant-oat01-…`, ~1-year lifetime, inference-scoped |
| Requirements | Claude Pro/Max/Team/Enterprise subscription (API-only Console accounts don't work) |
| Importer | None from the Claude CLI (it does not persist `setup-token` output). One-time legacy importer from this repo's `~/.claudemonitor/claudeoauth.json` |

### Fetch mechanism — probe call

```
POST https://api.anthropic.com/v1/messages
Authorization: Bearer <oauth_token>
anthropic-version: 2023-06-01
anthropic-beta: oauth-2025-04-20          ← required for OAuth bearer tokens
User-Agent: claude-code/<version>
Body: {"model": "<cheapest current model>", "max_tokens": 1,
       "messages": [{"role": "user", "content": "."}]}
```

- The probe model ID is a **maintained constant** (currently
  `claude-haiku-4-5-20251001`); a retired model ID is an expected failure mode
  — surface a distinct "update the app" error on 404/model-not-found.
- Each poll consumes one Haiku token of real inference, **which itself counts
  toward the account's usage**. Polling cost is negligible but nonzero; the
  host's default 120 s interval stands.

### Response parsing

Read response headers (case-insensitively; values arrive as strings):

| Header | → `LimitWindow` |
|---|---|
| `anthropic-ratelimit-unified-5h-utilization` / `-reset` | id `session-5h`, fraction used directly (already 0–1), reset from epoch seconds |
| `anthropic-ratelimit-unified-7d-utilization` / `-reset` | id `weekly` |
| `anthropic-ratelimit-unified-7d_sonnet-utilization` / `-reset` | id `model:sonnet-weekly` — **optional**, omit the window when headers are absent |

Header families may grow (the `7d_sonnet` lane appeared mid-life); the parser
scans for `anthropic-ratelimit-unified-<id>-utilization` generically and emits
a window per discovered `<id>`, with friendly labels for known ids.

### Status-code handling (normative — this is the §3.1 lesson)

| Response | Behavior |
|---|---|
| `200` | parse headers → snapshot |
| `429` **with** utilization headers | parse headers → snapshot (this is the at-100% case; the data is valid and the reset times are exactly what the user needs) |
| `429` without headers | error; host keeps prior snapshot as stale |
| `401` | distinct "token expired — run `claude setup-token`" state |
| other | error with truncated body; host keeps prior snapshot |

### Scheduling metadata

The plugin declares `minSpacingBetweenAccounts: 2s` — same-provider probes are
real inference requests and must stay staggered (host enforces; ADR-004).

### Test fixtures

Recorded real responses: `200` with all three header families; `200` without
the sonnet lane; `429` with headers; `429` without headers; `401`. Parser unit
tests assert fraction direction, epoch conversion, case-insensitivity, and the
generic `<id>` scan.

## Consequences

### Positive
- Battle-tested mechanism; every known edge case in this repo's history is
  encoded as a fixture.
- No refresh logic at all — the simplest plugin; good first implementation to
  validate the framework.

### Negative
- Polling costs real (tiny) inference usage and requires a maintained model ID.
- Headers are undocumented; Anthropic can change them silently. Generic
  `<id>` scanning absorbs additive change but not renames.

### Neutral
- Tokens are ~1-year and immutable: no rotation write-back path to test here
  (that's exercised by ADR-006).

## Alternatives Considered

### Alternative 1: Reuse Claude Code's own session credentials
Rejected — relitigated from this repo's history (ADR-001/003): session tokens
rotate constantly and foreign-keychain reads caused ACL friction. The
long-lived `setup-token` flow exists precisely for this use.

### Alternative 2: Scrape claude.ai usage UI
Heavier, needs browser cookies, and the web UI changes faster than the
headers. Rejected.

## References

- `docs/REBUILD-SPEC.md` §2–3 (this repo) — mechanism + lessons, including commit `073f9b9`
- ADR-004 — framework contract this plugin implements
