# ADR-004: Plugin framework for usage monitoring with vault-backed secrets

**Date:** 2026-06-11
**Status:** Accepted (2026-06-11; governs the successor repository)
**Deciders:** Owen Johnson, Claude (provider research 2026-06-11)

---

## Context

This app is being rebuilt from scratch in a new repository (see
`docs/REBUILD-SPEC.md`) with broader scope: monitoring usage for multiple
backends — initially **Anthropic (Claude)**, **OpenAI (Codex)**, and **Google
(Antigravity)** — with more expected later. Two architectural problems must be
solved once, up front:

**1. The current design is single-provider.** `UsageManager` hardcodes the
Anthropic probe endpoint, header names, auth shape, and a fixed
session/weekly/sonnet window trio all the way into the UI models.

Provider research (2026-06-11; sources at bottom) confirmed the usage surfaces
are heterogeneous on every axis — and all undocumented:

| | Auth material | Usage fetch | Data shape | Notable hazard |
|---|---|---|---|---|
| Anthropic | user-minted ~1yr OAuth token (`claude setup-token`) | 1-token probe inference call; read `anthropic-ratelimit-unified-*` response headers | used-fraction 0–1 per window, epoch resets | at 100% the probe 429s but headers must still be parsed |
| OpenAI Codex | Codex CLI OAuth tokens; **single-use rotating refresh token** | `GET chatgpt.com/backend-api/wham/usage` (or `codex app-server` JSON-RPC) | `used_percent` 0–100, window minutes, credits, dynamic extra windows | careless refresh permanently logs the user's CLI out |
| Google Antigravity | Google OAuth (successor to Gemini CLI auth) | Antigravity quota plumbing — to be specified in its provider ADR | per-model buckets; Gemini's API reported **remaining**, not used | Gemini CLI individual/Pro/Ultra tiers stop serving 2026-06-18; Antigravity replaces them. Prior art (ClaudeBar) already monitors Antigravity |

Provider breakage is a *when*, not an *if* — each integration must be isolated
so one provider's drift can't take down the app. Per-provider mechanics
(endpoints, refresh rules, parsing) are **out of scope here** and will be
specified in separate provider ADRs (planned: ADR-005 Anthropic, ADR-006
Codex, ADR-007 Antigravity).

**2. Secrets currently live in plaintext config.** Today
`~/.claudemonitor/claudeoauth.json` *is* both the account registry and the
secret store — tokens sit in a plaintext file that doubles as configuration.
Adding more providers multiplies the number of long-lived credentials at
stake. Requirement for the rebuild: **no secret material in config files.**

The repo's history also constrains the solution: ADR-001/ADR-003 record that
*reading another app's Keychain items* failed twice (rotating tokens, ACL
dialogs, subprocess overhead). That lesson is about foreign keychain items and
foreign credential lifecycles — it does not preclude an app-owned secret
store.

## Decision

The new app is a thin host around two seams: a **usage-plugin protocol** and a
**local secrets vault** with a companion CLI. Configuration registers services
and *references* secrets; the vault holds them; plugins receive them.

### 1. Plugin protocol and normalized domain model

Plugins are compiled-in Swift implementations of a single protocol, registered
in a static registry (no dynamic loading — see Alternatives).

```swift
struct LimitWindow {
    let id: String            // "session-5h", "weekly", "model:gpt-5.3-codex"
    let label: String         // display name
    let usedFraction: Double  // ALWAYS "used" (plugins invert remaining-style APIs), 0.0–1.0
    let resetsAt: Date?
    let windowDuration: TimeInterval?
}

struct UsageSnapshot {
    let windows: [LimitWindow]   // variable count — UI renders N rows, never assumes 3
    let planType: String?
    let credits: CreditInfo?     // optional everywhere
    let fetchedAt: Date
    let details: [String: String] // provider extras, opaque to the host
}

struct SecretSpec {
    let key: String              // e.g. "oauth_token", "refresh_token"
    let description: String      // shown by the CLI when prompting
    let mutable: Bool            // plugin may return an updated value (token rotation)
}

protocol UsagePlugin {
    static var providerID: String { get }     // "anthropic", "codex", "antigravity"
    static var secretSpecs: [SecretSpec] { get }
    func fetchUsage(account: AccountConfig, secrets: SecretBundle) async throws -> FetchResult
}

struct FetchResult {
    let snapshot: UsageSnapshot
    let updatedSecrets: [String: String]?  // host persists these to the vault (rotation write-back)
}
```

`secretSpecs` may be **empty**: a plugin may instead declare a *liveness
dependency* (it reads ephemeral state from a locally running process rather
than stored credentials — see ADR-007 Antigravity). The host renders
"provider not running" as an informational state distinct from errors, with
the previous snapshot shown as stale.

Normalization rules plugins own:
- **Direction:** everything converts to *used* fraction (invert remaining-style
  APIs inside the plugin, nowhere else).
- **Scale:** 0–1 fractions internally; conversion to display percent happens
  once in the UI with proper rounding (REBUILD-SPEC §3.3).
- **Times:** epoch seconds, ISO-8601, or relative seconds all normalize to `Date`.
- **Leniency:** parse numbers from string/int/float (providers disagree with
  their own schemas).

Host-owned cross-cutting behavior (no plugin reimplements these):
- **Stale-not-clobbered:** a plugin failure leaves the previous snapshot
  rendered as stale alongside the error; reset times are never replaced by a
  bare error (REBUILD-SPEC §3.1).
- **Scheduling:** the host staggers polls per provider (some polls are real
  inference requests) and may run different providers concurrently.
- **Logging:** secrets are masked centrally; plugins log through the host.

### 2. Secrets vault + CLI

A local encrypted vault, owned by the app (name TBD), managed through a
companion CLI:

```
<app> vault set <provider>/<account>/<key>     # prompts; never takes secret as argv
<app> vault list                               # names/metadata only, never values
<app> vault rm <provider>/<account>/<key>
<app> vault import <provider>                  # provider ADRs may define importers
                                               # (e.g. pull tokens from ~/.codex/auth.json)
<app> service add <provider> --name <label>    # writes config, prompts for declared secrets
```

Design points:

- **Storage:** one encrypted vault file (e.g. AES-GCM via CryptoKit) under the
  app's config directory. The data-encryption key is stored as an
  **app-owned** macOS Keychain item shared between app and CLI via the same
  keychain access group. This respects the ADR-003 lesson: the failures were
  reading *foreign* keychain items with foreign lifecycles; an item the app
  creates and owns has no ACL-dialog or rotation problem.
- **Addressing:** secrets are addressed `provider/account/key`, matching the
  plugin's declared `secretSpecs`.
- **Write-back:** when a plugin returns `updatedSecrets` (rotating refresh
  tokens), the host persists them to the vault atomically. Rotation handling
  is a framework feature, not a per-plugin hack.
- **No secret ever appears in:** config files, process arguments, logs, or
  error messages. The CLI prompts on stdin (or reads from a pipe) for values.
- **Migration:** a one-time importer moves tokens from the legacy
  `claudeoauth.json` shape into the vault.

### 3. Config = registry of services, no secrets

```jsonc
// ~/.{app}/config.json — safe to commit, sync, or screenshot
{
  "services": [
    {"provider": "anthropic",   "name": "Personal",  "pollSeconds": 120},
    {"provider": "anthropic",   "name": "Work"},
    {"provider": "codex",       "name": "Work"},
    {"provider": "antigravity", "name": "Personal"}
  ]
}
```

At startup and on each refresh the host: reads config → for each registered
service, resolves that plugin's `secretSpecs` from the vault
(`provider/name/key`) → invokes the plugin with the resolved `SecretBundle`.
A service whose secrets are missing renders as "needs setup — run
`<app> service add …`" rather than erroring opaquely.

Config keeps the current repo's ergonomics where they don't conflict:
re-read on every refresh cycle (no restart to add accounts), first service =
primary for the status bar, duplicate names rejected.

### 4. Provider ADRs

Each backend gets its own ADR specifying: credential acquisition and import
path, fetch mechanism, window mapping, refresh/rotation rules, failure modes,
and test fixtures. Planned:

- **ADR-005 Anthropic plugin** — probe-call mechanism, 429-with-headers rule,
  `claude setup-token` acquisition (port from this repo; REBUILD-SPEC §2–3).
- **ADR-006 Codex plugin** — `wham/usage` endpoint, `app-server` RPC fallback,
  the 8-day/JWT-expiry refresh policy and single-use-refresh-token safety,
  `vault import codex` from `~/.codex/auth.json`.
- **ADR-007 Antigravity plugin** — Antigravity quota/auth plumbing (research
  needed; ClaudeBar is prior art). The legacy Gemini CLI path
  (`retrieveUserQuota`) is documented in this PR's research notes but is not a
  build target — its consumer tiers stop serving 2026-06-18.

## Consequences

### Positive
- One provider's API drift breaks one plugin; host, UI, scheduler, and vault
  are untouched. New backends are a plugin + a provider ADR.
- Secrets get real hygiene: encrypted at rest, never in config/argv/logs,
  single audited write-back path for rotating tokens.
- Config becomes shareable/syncable since it carries no secret material.
- The variable-window model accommodates credits, per-model buckets, and
  future window shapes without UI rework.

### Negative
- More moving parts than today: vault + CLI + plugin registry vs. one JSON
  file. First-run setup requires the CLI (mitigated by `service add` doing
  config + secret prompts in one step).
- App-owned Keychain item + access-group sharing requires correct code
  signing/entitlements across app and CLI binaries.
- Vault write-back must be atomic and race-safe (CLI and app can both write).

### Neutral
- Plugins are compiled in; third parties extend by PR, not by dropping in a
  bundle. The protocol seam keeps a future out-of-process plugin mode open.
- Per-provider research already done (Codex, legacy Gemini) moves to the
  provider ADRs rather than living here.

## Alternatives Considered

### Alternative 1: Secrets stay in config files (status quo)
One plaintext JSON holding tokens. Rejected: multiplying providers multiplies
plaintext long-lived credentials; config can't be synced or shared; violates
the rebuild requirement outright.

### Alternative 2: Per-secret macOS Keychain items, no vault file
Store each secret as its own Keychain item. Workable, but: CLI access to many
items multiplies ACL/entitlement surface, portability and backup are awkward,
and listing/metadata UX is poor. A single encrypted file with one Keychain-held
key keeps Keychain's protection with file-level simplicity. The ADR-003
history also argues for minimizing Keychain surface area.

### Alternative 3: Plugins read provider CLIs' credential files directly
E.g. the Codex plugin reads `~/.codex/auth.json` at fetch time. Rejected as
the default: secrets would bypass the vault (no masking/rotation/audit path),
plugins would gain filesystem credential access, and foreign-file format drift
becomes a runtime failure. Instead, provider ADRs define **importers**
(`vault import codex`) so foreign credentials enter the vault explicitly, and
rotation write-back keeps them current.

### Alternative 4: Dynamically loaded plugin bundles
Out-of-process or `dlopen`-style plugins. Rejected for now: code-signing and
sandbox complexity, secret-passing across process boundaries, and no current
third-party demand. The protocol is the seam; dynamic loading can come later
without redesign.

## References

- `docs/REBUILD-SPEC.md` (this repo) — Anthropic mechanism + portable lessons
- ADR-001 / ADR-003 (this repo) — Keychain history motivating the vault design
- Provider research (2026-06-11), to be carried into ADR-005/006/007:
  - Codex auth/storage: https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/storage.rs and `manager.rs`
  - Codex usage surfaces: https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/rate_limits.rs, https://github.com/openai/codex/blob/main/codex-rs/codex-backend-openapi-models/src/models/rate_limit_status_payload.rs, https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2/account.rs
  - Codex limit semantics: https://developers.openai.com/codex/pricing
  - Gemini CLI sunset notice (motivates Antigravity): https://developers.google.com/gemini-code-assist/resources/quotas
  - Legacy Gemini quota endpoint (historical reference): https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/types.ts
- Prior art: https://github.com/steipete/CodexBar, https://github.com/tddworks/ClaudeBar (includes Antigravity), https://github.com/Dicklesworthstone/coding_agent_usage_tracker
