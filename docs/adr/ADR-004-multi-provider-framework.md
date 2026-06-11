# ADR-004: Multi-provider usage-monitoring framework (Anthropic, OpenAI Codex, Google Gemini)

**Date:** 2026-06-11
**Status:** Proposed (for the successor repository)
**Deciders:** Owen Johnson, Claude (provider research 2026-06-11)

---

## Context

This app is being rebuilt from scratch in a new repository (see
`docs/REBUILD-SPEC.md`), with new scope: monitoring usage for **OpenAI Codex**
and **Google Gemini** accounts alongside Claude. The current architecture is
Anthropic-specific — `UsageManager` hardcodes the probe endpoint, header names,
auth header shape, and the session/weekly/sonnet window trio all the way into
the UI models.

Research into the three providers (2026-06-11, sources at bottom) shows the
usage surfaces are **fundamentally different** — different auth sources,
different fetch mechanisms, different data shapes, different failure modes.
None of the three is a documented, stable API.

### Provider survey

| | Anthropic (Claude) | OpenAI (Codex) | Google (Gemini CLI) |
|---|---|---|---|
| Credential source | User-minted long-lived token via `claude setup-token`, stored in app's own `~/.claudemonitor/claudeoauth.json` | Codex CLI's `~/.codex/auth.json` (or OS keyring when `cli_auth_credentials_store=keyring/auto`) | Gemini CLI's `~/.gemini/oauth_creds.json` |
| Token lifetime | ~1 year, no refresh | OAuth access token (short) + **single-use rotating** refresh token | Google OAuth ~1h access + refresh token |
| Refresh mechanism | none needed | `POST auth.openai.com/oauth/token`; **danger:** reusing a rotated refresh token permanently kills the CLI session | standard `POST oauth2.googleapis.com/token` using the CLI's embedded public client ID/secret |
| Usage fetch | **Probe inference call** (1-token Haiku message), read `anthropic-ratelimit-unified-*` response headers | **Dedicated endpoint** `GET chatgpt.com/backend-api/wham/usage` (Bearer + `chatgpt-account-id` header) | **Dedicated endpoint** `POST cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`; tier/project via `:loadCodeAssist` |
| Data shape | used fraction 0–1 per window + epoch reset | `used_percent` 0–100 per window + `reset_at` epoch + window minutes; credits balance; `additional_rate_limits[]` | **`remainingFraction`** 0–1 (inverted!) per model bucket + ISO-8601 `resetTime` |
| Windows | 5h session, 7d weekly, 7d Sonnet | primary ≈ 5h, secondary ≈ 7d (token-consumption metered), per-model extras | per-model daily request quota |
| Cost of a poll | 1 Haiku token (paid inference) | free (read-only endpoint) | free (read-only endpoint) |
| At-limit behavior | probe returns **429 that still carries the headers** (must parse — see REBUILD-SPEC §3.1) | endpoint still readable; `rate_limit_reached_type` distinguishes cap types | quota API omits `remainingAmount` at 100%-remaining (known stale-cache bug source) |
| Stability | undocumented headers | undocumented endpoint; header families already changed once | `v1internal` private API; **service sunset announced 2026-06-18** for individual/Pro/Ultra tiers (migration: Antigravity) |

Forces:

- All three surfaces are undocumented and provider-breakage is a *when*, not an
  *if*. The architecture must localize breakage to one adapter.
- The UI must not assume Anthropic's fixed three-window shape: Codex has
  credits and dynamic extra windows; Gemini has per-model buckets.
- Codex token refresh is hazardous (single-use rotation); a careless
  implementation breaks the user's Codex CLI login.
- Gemini's primary OAuth path may die a week after this ADR; Antigravity
  support must be addable without rework.
- Prior art exists and validates the pattern: CodexBar (Swift menubar,
  Codex+Gemini), ClaudeBar (Claude+Codex+Gemini+Antigravity), and
  coding_agent_usage_tracker all ship exactly these mechanisms.

## Decision

Build the new app around a **provider-adapter protocol** with a normalized
domain model. Provider-specific knowledge lives only inside adapters.

### Normalized domain model

```swift
struct LimitWindow {
    let id: String            // "session-5h", "weekly", "model:gemini-2.5-pro"
    let label: String         // display name
    let usedFraction: Double  // ALWAYS used (not remaining), 0.0–1.0
    let resetsAt: Date?
    let windowDuration: TimeInterval?
}

struct UsageSnapshot {
    let windows: [LimitWindow]       // variable count — UI renders N rows
    let planType: String?            // "max", "pro", "free-tier", …
    let credits: CreditInfo?         // Codex only today; optional everywhere
    let fetchedAt: Date
}

protocol ProviderAdapter {
    var providerID: String { get }
    func discoverAccounts() async throws -> [ProviderAccount]   // from cred files
    func fetchUsage(for account: ProviderAccount) async throws -> UsageSnapshot
}
```

Normalization rules the adapters own:

- **Direction:** everything converts to *used* fraction (Gemini reports
  `remainingFraction` — invert in the adapter, nowhere else).
- **Scale:** fractions 0–1 internally; rounding to display percent happens once
  in the UI layer (with proper rounding — REBUILD-SPEC §3.3).
- **Reset times:** epoch seconds (Anthropic, Codex) and ISO-8601 (Gemini) both
  normalize to `Date`.
- **Type leniency:** parse numbers from strings/int/float (Codex `used_percent`
  is `f64` in headers but `i32` in the OpenAPI body model).

### Per-adapter implementation notes (binding)

**Anthropic** — port as-is from this repo, including the 429-with-headers rule,
staggered sequential probes, and file-based token storage (REBUILD-SPEC §3).

**Codex** — read `~/.codex/auth.json` (handle keyring-only installs by
degrading gracefully); call `wham/usage`; map `primary_window`/
`secondary_window`/`additional_rate_limits[]` to windows and surface credits.
**Token-refresh policy (safety-critical):** mirror Codex CLI's own behavior —
refresh only when `last_refresh` is older than 8 days OR the JWT `exp` is
within ~5 minutes, and **write the rotated tokens back to `auth.json`
atomically**. Never refresh speculatively: refresh tokens are single-use, and
burning one logs the user out of their own CLI. Fallback path if the file
format shifts: spawn `codex app-server` and use the JSON-RPC
`account/rateLimits/read` method (typed, versioned — degrades with deprecation
paths instead of silently).

**Gemini** — read `~/.gemini/oauth_creds.json`; refresh via the CLI's embedded
public OAuth client (standard installed-app pattern; CodexBar does the same);
`loadCodeAssist` → tier + `cloudaicompanionProject`; `retrieveUserQuota` →
per-model buckets. Treat a missing `remainingAmount` as "100% remaining", not
as stale data. **Plan for the 2026-06-18 sunset:** structure the Gemini adapter
so an Antigravity adapter can replace/join it; do not invest in the API-key
path (no quota endpoint exists — static limits + 429 `QuotaFailure` parsing
only) unless users ask.

### Cross-cutting rules (lifted from this repo's lessons)

1. **Never clobber last-known reset times with an error** — every adapter
   failure leaves the previous `UsageSnapshot` rendered as stale alongside the
   error (REBUILD-SPEC §3.1).
2. **Stagger same-provider polls** (Anthropic especially — its poll is a real
   inference request); cross-provider polls may run concurrently.
3. **Secrets hygiene:** mask tokens in logs (last 6 chars), never write
   credentials anywhere except their canonical store, mode 600 on owned files.
4. **Fixture-tested parsers:** each adapter ships recorded real responses
   (200, at-limit, error) as test fixtures so provider drift is caught by a
   failing test, not a user report.

## Consequences

### Positive
- Provider breakage is contained to one adapter; the UI and scheduler never change.
- Variable-window model accommodates Codex credits/extra lanes and Gemini
  per-model buckets without UI rework, and leaves room for Antigravity.
- Reusing the CLIs' own credential stores means zero extra login UX for Codex
  and Gemini (Claude keeps its token-file flow since `claude setup-token`
  output isn't persisted by the CLI).

### Negative
- Three undocumented surfaces ≈ three independent breakage clocks; maintenance
  burden grows with each provider.
- Reading other apps' credential files is inherently fragile (paths, formats,
  keyring migration) and may read as invasive to some users — must stay
  read-only except for the documented Codex token write-back.
- Codex refresh write-back is a real correctness risk (file race with a running
  CLI); requires atomic write + file locking care.

### Neutral
- The normalized model slightly flattens provider-specific nuance (e.g. Codex
  `spend_control`); adapters can expose extras via an opaque `details` field
  when the UI grows to need them.

## Alternatives Considered

### Alternative 1: Extend the current Anthropic-shaped model
Keep `UsageData` (session/weekly/sonnet) and map other providers onto it.
Rejected: Codex credits and Gemini per-model buckets don't fit three fixed
slots; the mapping would lie to users and break first.

### Alternative 2: Shell out to each CLI and parse human output
Run `claude /status`-equivalents and scrape text. Rejected as primary: output
text changes constantly, requires the CLIs installed and on PATH, and spawns
processes per poll. Exception: `codex app-server` JSON-RPC is a *structured*
CLI surface and is retained as the Codex fallback path.

### Alternative 3: Web-dashboard scraping (hidden WebView + browser cookies)
CodexBar offers this as an opt-in extra. Rejected for core: heaviest, most
fragile, and cookie import raises the privacy bar far above reading local CLI
credential files.

## References

- `docs/REBUILD-SPEC.md` (this repo) — Anthropic mechanism + lessons
- Codex auth/storage: https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/storage.rs and `manager.rs`
- Codex rate-limit headers/SSE: https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/rate_limits.rs
- Codex usage payload models: https://github.com/openai/codex/blob/main/codex-rs/codex-backend-openapi-models/src/models/rate_limit_status_payload.rs
- Codex app-server protocol: https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2/account.rs
- Codex limits semantics: https://developers.openai.com/codex/pricing
- Gemini CLI oauth: https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/oauth2.ts
- Gemini quota endpoint types: https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/types.ts (PR #13843)
- Gemini quotas + sunset notice: https://developers.google.com/gemini-code-assist/resources/quotas
- Gemini API-key rate limits: https://ai.google.dev/gemini-api/docs/rate-limits
- Prior art: https://github.com/steipete/CodexBar (esp. `docs/codex.md`, `docs/gemini.md`), https://github.com/tddworks/ClaudeBar, https://github.com/Dicklesworthstone/coding_agent_usage_tracker
