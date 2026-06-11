# ADR-006: OpenAI Codex usage plugin

**Date:** 2026-06-11
**Status:** Proposed (for the successor repository)
**Deciders:** Owen Johnson, Claude (provider research 2026-06-11)

---

## Context

ADR-004 defines the plugin framework. This ADR specifies the Codex plugin —
monitoring ChatGPT-plan Codex usage (5-hour and weekly windows, credits).

Codex differs from Anthropic in two load-bearing ways:

1. **There is a real usage endpoint** (`GET chatgpt.com/backend-api/wham/usage`,
   undocumented) — no probe inference call needed; polls are free.
2. **Credential custody is shared with the Codex CLI.** Tokens live in the
   CLI's `~/.codex/auth.json`; access tokens are short-lived JWTs and the
   **refresh token is single-use and rotating** — whoever redeems it
   invalidates every other copy. A monitoring app that refreshes carelessly
   logs the user out of their own CLI. This is the central design problem.

Research findings (2026-06-11, sources at bottom): auth file schema
(`AuthDotJson`: `OPENAI_API_KEY?`, `tokens{id_token, access_token,
refresh_token, account_id}`, `last_refresh`), Codex's own refresh policy
(refresh when `last_refresh` > 8 days, or JWT `exp` within 5 min; endpoint
`POST auth.openai.com/oauth/token`), the keyring storage option
(`cli_auth_credentials_store = file|keyring|auto` — `auth.json` may not
exist), the usage payload (`RateLimitStatusPayload`: `plan_type`,
`rate_limit{primary_window, secondary_window}`, `credits`,
`additional_rate_limits[]`, `rate_limit_reached_type`; window snapshot =
`{used_percent, limit_window_seconds, reset_after_seconds, reset_at}`), and a
typed JSON-RPC alternative (`codex app-server` → `account/rateLimits/read`).
Prior art: CodexBar implements exactly this stack.

## Decision

### Credential custody model: the Codex CLI stays the authority

The vault holds a **mirror** of the CLI's credentials, not an independent
copy. This is the documented exception to ADR-004's "no foreign file reads"
default, confined to an explicit sync component:

- `vault import codex` reads `~/.codex/auth.json` (honoring `$CODEX_HOME`)
  into `codex/<account>/…` vault keys: `access_token`, `refresh_token`,
  `account_id`, `last_refresh` (all marked mutable).
- A **pre-fetch sync step** (host-invoked, part of the plugin package)
  re-reads `auth.json` before each poll. If the CLI has refreshed since our
  mirror (newer `last_refresh`), the vault mirror is updated — the CLI does
  the refreshing whenever possible and we just follow.

### Token freshness policy (safety-critical, in priority order)

1. **Use the mirrored access token** while its JWT `exp` is > 5 minutes away.
2. **Expired? Re-read `auth.json` first** — the CLI has likely refreshed;
   adopt its tokens.
3. **Only then refresh ourselves**: `POST auth.openai.com/oauth/token`, and
   **atomically write the rotated tokens back to BOTH the vault and
   `auth.json`** (temp-file + rename; mirror Codex's own file format exactly).
   Skipping the `auth.json` write-back would strand the CLI on a dead
   refresh token — the one unforgivable failure mode.
4. Refresh failures ("expired" / "already used" / "revoked") are terminal:
   surface "re-login with `codex login`, then `<app> vault import codex`".

`auth.json` absent (keyring storage mode, or never logged in): degrade to the
RPC fallback below, else show "needs setup" with guidance.

### Fetch mechanism — primary

```
GET https://chatgpt.com/backend-api/wham/usage
Authorization: Bearer <access_token>
chatgpt-account-id: <account_id>
```

Mapping `RateLimitStatusPayload` → `UsageSnapshot`:

| Payload | → |
|---|---|
| `rate_limit.primary_window {used_percent, limit_window_seconds, reset_at}` | window id `primary`, label from `limit_window_seconds` (≈5 h today — **derive the label from the payload**, never hardcode), `usedFraction = used_percent / 100` |
| `rate_limit.secondary_window` | window id `secondary` (≈weekly) |
| `additional_rate_limits[]` | one window per entry, id `extra:<limit-name>` (model-specific lanes, e.g. Codex Spark) |
| `credits {balance, unlimited, has_credits}` | `CreditInfo` |
| `plan_type` | `planType` |
| `rate_limit_reached_type` | `details` (distinguishes plain limit vs workspace credit/cap exhaustion) |

Parse `used_percent` leniently — it is `f64` in the header surface but `i32`
in the OpenAPI body model; accept int, float, or numeric string.

### Fetch mechanism — fallback

`codex app-server` JSON-RPC over stdio (spawn
`codex -s read-only -a untrusted app-server`; `initialize` →
`account/rateLimits/read`). Typed and versioned (v2) — it degrades with
deprecation paths instead of silently. Used when: `auth.json` is
keyring-only, the endpoint schema breaks, or the user opts in
(`"transport": "rpc"` in the service config). Requires the `codex` binary on
PATH; heavier per poll (process spawn), so it is not the default.

### Failure modes & fixtures

| Condition | Behavior |
|---|---|
| 401 | run the freshness policy once (steps 2–3), retry once, then error |
| endpoint schema drift | fixture-tested parser fails loudly; fall back to RPC |
| `auth.json` format drift | sync step fails with "update the app" error; RPC fallback |
| at-limit | endpoint stays readable — no special casing needed (unlike Anthropic's 429) |

Fixtures: recorded `wham/usage` responses (normal, at-limit,
with `additional_rate_limits`, with credits exhausted), an `auth.json` sample,
JWT-expiry parsing cases, and an RPC `account/rateLimits/read` response.

## Consequences

### Positive
- Free, low-latency polls with rich data (credits, plan, dynamic lanes) —
  no inference cost.
- The CLI-as-authority model means in steady state we never touch the refresh
  token; rotation risk only arises when the CLI has been idle > 8 days.
- The RPC fallback gives a second, independently-shaped source when the
  undocumented endpoint drifts.

### Negative
- Dual-custody sync (vault ↔ `auth.json`) is the most delicate code in the
  app: races with a running CLI require atomic writes and mtime checks.
- `wham/usage` is undocumented and has already evolved (header families,
  `additional_rate_limits`, `spend_control` were all additive changes).
- Keyring storage mode has no file to import — RPC-only for those users.

### Neutral
- This plugin exercises the framework's rotation write-back path
  (`FetchResult.updatedSecrets`) — it is the validation case for that feature.

## Alternatives Considered

### Alternative 1: Vault-only custody (import once, refresh independently)
Rejected: first independent refresh rotates the single-use token and kills the
user's CLI session. Custody must stay with the CLI.

### Alternative 2: RPC as the primary transport
Spawning `codex app-server` per poll avoids all token handling. Rejected as
default: process-spawn overhead per poll, requires `codex` on PATH, and the
endpoint path is what all prior art ships as primary. Retained as fallback.

### Alternative 3: Scrape the usage dashboard (WebView + cookies)
CodexBar offers it opt-in for dashboard-only extras. Rejected: heaviest,
most fragile, cookie import raises the privacy bar.

## References

- Auth storage/refresh: https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/storage.rs, …/auth/manager.rs
- Usage payload models: https://github.com/openai/codex/blob/main/codex-rs/codex-backend-openapi-models/src/models/rate_limit_status_payload.rs, …/rate_limit_window_snapshot.rs
- Header/SSE surfaces: https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/rate_limits.rs
- app-server protocol: https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2/account.rs
- Limit semantics: https://developers.openai.com/codex/pricing
- Prior art: https://github.com/steipete/codexbar (`docs/codex.md`)
- ADR-004 — framework contract this plugin implements
