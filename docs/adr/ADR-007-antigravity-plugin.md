# ADR-007: Google Antigravity usage plugin

**Date:** 2026-06-11
**Status:** Proposed (for the successor repository)
**Deciders:** Owen Johnson, Claude (provider research 2026-06-11)

---

## Context

ADR-004 names Antigravity as the Google backend (the Gemini CLI consumer
tiers stop serving 2026-06-18). Research (2026-06-11, sources at bottom)
found Antigravity is the most constrained provider of the three — legally,
not just technically:

1. **ToS prohibits third-party token use, with enforcement.** Antigravity's
   terms prohibit use with third-party products; Google has reportedly banned
   accounts that used third-party auth plugins, and the SDK docs state that
   extracting/storing/transmitting OAuth tokens (or reading the IDE's
   `state.vscdb` directly) can trigger permanent bans. The OAuth client
   ID/secret are deliberately non-public (third-party tools scrape them from
   the app bundle — a path that has already broken twice).
2. **A lower-risk local surface exists.** The Antigravity IDE and CLI (`agy`)
   run a bundled language server (Windsurf/Codeium-derived) exposing a
   localhost Connect/gRPC endpoint that reports per-model quota. Probing it
   lifts no OAuth token and makes no Google network call. Both ClaudeBar and
   CodexBar use this as their default path.
3. **Quota semantics are per-model buckets reported as *remaining*** fraction
   plus a reset time, with documented-prose limits (5-hour refresh for paid
   tiers, weekly caps, combined Flash/Pro lanes) that are vague, have changed
   repeatedly, and are contradicted by user reports (multi-day lockouts).
   The API-reported `resetTime` is the only trustworthy reset signal.

## Decision

### Transport: local language-server probe only (v1)

The plugin reads quota from the running Antigravity language server. **No
remote Google API calls, no OAuth token handling.**

Discovery:
1. Find candidate processes: `pgrep -lf language_server` (binary names seen:
   `language_server`, `language_server_macos`, `language_server_macos_arm` —
   2.0 dropped the suffix; treat the name list as a maintained constant).
2. Validate provenance: IDE processes carry `--app_data_dir antigravity` or an
   `/antigravity/` path; CLI matches `agy`/`antigravity-cli`/`antigravity_cli`.
3. Extract from process args: `--csrf_token <token>` and
   `--extension_server_port <port>`; enumerate listening ports via `lsof`.

Probe:

```
POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/GetUserStatus
X-Codeium-Csrf-Token: <token>
Connect-Protocol-Version: 1
Content-Type: application/json
Body: {"metadata":{"ideName":"antigravity","extensionName":"antigravity",
       "ideVersion":"unknown","locale":"en"}}
```

Fallback service path: `…/GetCommandModelConfigs`. TLS is a self-signed
localhost cert — use a loopback-scoped insecure TLS client; fall back to
plain HTTP on the extension port.

Parsing → `UsageSnapshot`:

| Response field | → |
|---|---|
| `userStatus.cascadeModelConfigData.clientModelConfigs[]` | one `LimitWindow` per model: id `model:<modelOrAlias.model>`, label from `label` |
| `quotaInfo.remainingFraction` (0–1) | `usedFraction = 1 − remainingFraction` (**inversion happens here, per ADR-004**) |
| `quotaInfo.resetTime` (ISO-8601 or epoch seconds) | `resetsAt` (accept both encodings) |
| `userStatus.email` | account identity check |

Aggregation: the status-bar summary uses the **most-constrained** model family
(highest used fraction), mirroring prior art; noisy per-model rows may be
filtered by a maintained label allowlist.

### Secrets: none stored

This plugin declares an **empty `secretSpecs`** — the CSRF token is read from
the live process's arguments at fetch time and never persisted. The vault is
not involved. Framework implication (flows back into ADR-004's contract): a
plugin may have a **liveness dependency instead of a secret dependency**, and
the host must render that state distinctly:

- No Antigravity process found → "Antigravity not running" (informational,
  not an error; previous snapshot shown as stale with its age).
- Process found but no CSRF token in args → "authentication required" (open
  Antigravity and sign in). Exception: an explicit CLI-process match may
  proceed with an empty CSRF token (observed CLI behavior in prior art).

### Quota interpretation rules

- Trust `resetTime` over any advertised cadence (5-hour/weekly prose has
  repeatedly diverged from reality; multi-day lockouts are widely reported).
- A response where **every** model reports 100% remaining is suspect (known
  false-full bug family on Antigravity's quota surfaces) — mark the snapshot
  low-confidence in `details` rather than overwriting a recent contradictory
  snapshot.
- Plan/tier from `GetUserStatus` populates `planType` when present.

### Failure modes & fixtures

| Condition | Behavior |
|---|---|
| no process | "not running" state, stale snapshot retained |
| process rename / flag rename (has happened) | discovery fails loudly → "update the app" guidance |
| service path / field drift | fixture-tested parser fails loudly |
| TLS handshake failure | retry once via HTTP extension port, then error |

Fixtures: recorded `GetUserStatus` and `GetCommandModelConfigs` responses
(normal, multi-model, all-100%-remaining suspect case), process-arg parsing
cases (IDE suffixed/unsuffixed binaries, CLI with empty CSRF), and both
`resetTime` encodings.

## Consequences

### Positive
- Zero stored secrets and zero Google-API calls: the lowest ToS/ban exposure
  available, and no OAuth client scraping.
- Per-model windows fit the ADR-004 variable-window model with no UI work.
- Validates the framework's "liveness dependency" plugin shape.

### Negative
- **Quota is only readable while Antigravity (IDE or CLI) is running.** When
  it isn't, the app shows the last snapshot as stale. (Prior art accepts the
  same limitation in its default mode.)
- Every load-bearing detail is reverse-engineered from Windsurf/Codeium-
  derived plumbing: process names (changed once already), flag names, the
  `exa.language_server_pb` service path, and the `X-Codeium-Csrf-Token`
  header are all rename-prone. Expect maintenance every few Antigravity
  releases; the fixture suite is the early-warning system.
- Quota semantics themselves are unstable (Google has changed tiers, lanes,
  and limits repeatedly since launch).

### Neutral
- Antigravity's own data-quality problems (false-full reports, reset-time
  drift) are surfaced, not corrected — the app reports what the server says,
  flagged when suspect.

## Alternatives Considered

### Alternative 1: Remote cloudcode-pa OAuth path
`POST cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels` (with
`loadCodeAssist`/`onboardUser`/`retrieveUserQuota`) using the user's OAuth
token — works with the IDE closed, and CodexBar implements it. **Rejected for
v1:** it requires lifting the OAuth token (from `state.vscdb` or keyring) and
scraping the non-public OAuth client from the app bundle — both squarely in
the conduct Google's ToS prohibits and has reportedly banned accounts for.
Revisit only if Google publishes a sanctioned surface; if ever built, it must
be opt-in behind an explicit account-risk warning.

### Alternative 2: Read the IDE's `state.vscdb` / CLI keyring directly
The IDE token is extractable from SQLite+protobuf; the CLI token is
keyring-locked ("strictly enforced"). Rejected: same ToS exposure as
Alternative 1 plus brittle binary formats, with no benefit over the local
probe while Antigravity is running.

### Alternative 3: Wait for an official usage API
Cleanest, but nothing is announced, and the Gemini CLI sunset forces a Google
story now. The local probe ships v1; this alternative remains the standing
preference if Google provides one.

## References

- ClaudeBar local probe (primary prior art): https://github.com/tddworks/ClaudeBar/blob/main/Sources/Infrastructure/Antigravity/AntigravityUsageProbe.swift
- CodexBar Antigravity stack (local + remote, churn history): https://github.com/steipete/CodexBar/blob/main/docs/antigravity.md, `Sources/CodexBarCore/Providers/Antigravity/*.swift`, CHANGELOG entries #1049/#1053/#1076/#1209/#1334/#1341
- Plan/limit prose: https://blog.google/feed/new-antigravity-rate-limits-pro-ultra-subsribers/, https://antigravity.google/blog/changes-to-antigravity-plans
- Reset-reliability reports: https://discuss.ai.google.dev/t/google-ai-pro-antigravity-quota-shows-multi-day-lockouts-instead-of-5-hour-reset/130202
- ADR-004 — framework contract this plugin implements (empty-secretSpecs / liveness-dependency note flows back into its contract)
