# Rebuild Specification — Claude Monitor

**Purpose:** This repo will be recreated from scratch in a new repository (with added
multi-provider support — see ADR-004). This document distills the functional
requirements and, more importantly, the hard-won lessons that live only in git
history and ADRs. A from-scratch rewrite that ignores this document will
re-discover every one of these the slow way.

**Stable reference:** tag `v1.0-final` in this repo is the snapshot this spec describes.

---

## 1. What the app is

A native Swift macOS menubar app (macOS 13+) that shows Claude subscription usage
limits at a glance for one or more accounts:

- Status bar: SF Symbol icon with color-coded indicator + primary account's session percentage.
- Dropdown popover: per-account accordion rows showing **session (5h)**, **weekly (7d)**,
  and **weekly Sonnet (7d_sonnet)** utilization with progress bars and time-until-reset.
- Color thresholds: green < 70%, orange ≥ 70%, red ≥ 90%.
- Auto-refresh every 120 seconds (`Timer.scheduledTimer` in the AppDelegate), plus
  manual refresh button.
- Optional launch-at-login (macOS Login Items) and update check against
  `api.github.com/repos/<repo>/releases/latest`.

## 2. How usage detection works (Anthropic)

There is **no usage API**. The app makes a minimal inference call and reads
rate-limit response headers:

```
POST https://api.anthropic.com/v1/messages
Authorization: Bearer <sk-ant-oat01-… long-lived OAuth token>
anthropic-version: 2023-06-01
anthropic-beta: oauth-2025-04-20        ← required for OAuth bearer tokens
User-Agent: claude-code/<version>
Body: {"model": "claude-haiku-4-5-20251001", "max_tokens": 1,
       "messages": [{"role": "user", "content": "."}]}
```

Headers read (values are **0.0–1.0 fractions**; resets are **Unix epoch seconds**):

| Header | Meaning |
|---|---|
| `anthropic-ratelimit-unified-5h-utilization` | session window usage |
| `anthropic-ratelimit-unified-5h-reset` | session reset time |
| `anthropic-ratelimit-unified-7d-utilization` | weekly usage |
| `anthropic-ratelimit-unified-7d-reset` | weekly reset time |
| `anthropic-ratelimit-unified-7d_sonnet-utilization` | weekly Sonnet usage (may be absent) |
| `anthropic-ratelimit-unified-7d_sonnet-reset` | weekly Sonnet reset (may be absent) |

This is **undocumented API behavior** and may change without notice. Header
lookup must be case-insensitive (the code checks both original and lowercased
names). The probe costs one Haiku token per account per refresh.

## 3. Lessons a rewrite WILL reintroduce if ignored

These are ordered by how expensive they were to learn.

### 3.1 Parse rate-limit headers from 429 responses too (commit `073f9b9`)

When an account hits **100% utilization, the probe call itself returns 429** —
but the 429 still carries the utilization and reset headers. The original code
treated any non-200 as an error, so at exactly the moment the user most needs
"when does my limit reset?", the app showed an error and lost the reset times.

Required behavior:
- Accept usage data from `200`, **and from `429` when utilization headers are present**.
- A `429` *without* headers is an error.
- The UI must show cached usage data (grayed/stale) *alongside* an error message
  during transient failures — never replace last-known reset times with a bare error.

### 3.2 Token storage: file-based, not Keychain (ADR-001 → ADR-003 → commit `c3c3eb5`)

The storage story went through three generations — don't repeat the loop:

1. **v1.x:** read Claude Code's own keychain entry (`Claude Code-credentials`) to
   reuse its session token. Failed: Claude Code **rotates short-lived session
   tokens**, so the app constantly broke; reading another app's keychain item
   triggers ACL dialogs; `SecItemCopyMatching` vs `security` CLI each had problems
   (ACL prompts vs subprocess overhead).
2. **Interim:** app-owned Keychain storage. Still produced reliability problems
   and prompt friction.
3. **Final:** plain file `~/.claudemonitor/claudeoauth.json` (mode 600) holding
   user-minted **long-lived** tokens from `claude setup-token` (`sk-ant-oat01-…`,
   ~1-year lifetime, requires Pro/Max/Team/Enterprise subscription).

A fresh agent will gravitate to Keychain as the "correct macOS pattern."
The decision to use a file was deliberate. Keep it (or document a reversal as
a new ADR).

### 3.3 Percentage truncation bug (ADR-003)

`Int(89.7)` truncates to 89 — displayed values systematically understated
utilization and threshold crossings (70/90) fired late. Use proper rounding
when converting utilization fractions to display percentages.

### 3.4 Sequential refresh with stagger — NOT parallel

`refreshAllAccounts()` fetches accounts **sequentially with a 2-second sleep
between accounts** to avoid tripping rate limiting / abuse heuristics with
simultaneous probes. The README's claim of "concurrent refresh via TaskGroup"
is stale — the code is deliberately sequential. Preserve the stagger (or
document why parallel is safe).

### 3.5 Smaller behaviors that matter

- **Token file is re-read on every refresh cycle** — adding/removing accounts
  requires no app restart.
- Token file supports two formats: `["token", …]` (legacy) and
  `[{"token": …, "name": …}, …]`. Empty tokens filtered out.
- **Duplicate `name` values are silently skipped** (name doubles as account ID).
  Unnamed tokens get fallback ID `account-N (…last6)`.
- `~/.claudemonitor/config.json` `{"tokenFile": "…"}` overrides the token file
  path; `~` is expanded.
- First token in the file = primary account = status bar display.
- Tokens are **masked in logs** (last 6 chars only). Logs at `~/.claudemonitor/logs/`.
- 401 → user-facing "Token expired (401)" (regenerate with `claude setup-token`).
- Account metadata persisted in `UserDefaults` under `claudeusage.accounts`;
  cached usage shown as stale on startup until first refresh.
- Popover height is computed (capped ~480pt) — multi-account accordion with
  compact 20pt usage rows (ADR-003 superseded ADR-002's "pixel-identical" rule).

## 4. Architecture pointers (current repo)

| File | Responsibility |
|---|---|
| `ClaudeMonitorApp.swift` | AppDelegate, status item, 120s timer, popover sizing |
| `UsageManager.swift` | config/token file IO, probe call, header parsing, account state (`@MainActor ObservableObject`) |
| `AccountModels.swift` | `AccountRecord`, `AccountUsage`, `UsageData` |
| `UsageView.swift` / `AccountList.swift` / `AccountRow.swift` / `AccountDetail.swift` / `UsageRow.swift` | SwiftUI popover UI |
| `SharedStyles.swift` | color thresholds (`Color.forUtilization`) |

ADRs: `docs/adr/ADR-001` (multi-account), `ADR-002` (compact accordion UI),
`ADR-003` (compact rows, rounding fix, keychain history). Process/retro docs in
`docs/impl/` record how each phase was built.

## 5. Requirements for the rewrite

Functional parity checklist:

- [ ] Multi-account monitoring from a user-editable token file (no restart to pick up changes)
- [ ] Session / weekly / model-specific utilization + reset countdowns per account
- [ ] Usage-from-429 behavior (§3.1) and stale-data-with-error UI
- [ ] Color thresholds 70/90 with correct rounding (§3.3)
- [ ] Staggered sequential refresh (§3.4), 120s cycle, manual refresh
- [ ] Status bar icon: color + primary-account percentage
- [ ] Launch at login, GitHub release update check
- [ ] No telemetry; credentials never leave the machine except to the provider's own API
- [ ] Masked-token file logging for debugging

New scope (see ADR-004): provider-adapter architecture for Anthropic + OpenAI
Codex + Google Gemini. **Do not** generalize from Anthropic's header shape —
each provider has a different auth source, probe method, usage model, and
reset semantics. ADR-004 records the research and the abstraction decision.
