# Claude Monitor

<p align="center">
  <img src="Xnapper-2026-01-09-11.22.53.png" alt="Claude Monitor Screenshot" width="300">
</p>

A lightweight macOS menubar app that displays your Claude Code usage limits at a glance.

Originally built by [@richhickson](https://x.com/richhickson). Forked and maintained by [@owenjohnson](https://github.com/owenjohnson).

## Features

- 🔄 **Auto-refresh** every 60 seconds with retry logic
- 🚦 **Color-coded status** — Green (OK), Yellow (>70%), Red (>90%)
- ⏱️ **Time until reset** for both session and weekly limits
- 📊 **Session & Weekly limits** displayed together
- 👥 **Multi-account support** — monitor multiple Claude accounts simultaneously
- 🪶 **Lightweight** — Native Swift, minimal resources

## Installation

### Download

1. Go to [Releases](../../releases)
2. Download `ClaudeMonitor.zip`
3. Unzip and drag `ClaudeMonitor.app` to your Applications folder
4. Open the app (you may need to right-click → Open the first time)

### Build from Source

```bash
git clone https://github.com/owenjohnson/claudemonitor.git
cd claudemonitor
open ClaudeMonitor.xcodeproj
```

Then build with ⌘B and run with ⌘R.

## Requirements

- macOS 13.0 (Ventura) or later
- Claude Code CLI installed and logged in

## Setup

1. Install [Claude Code](https://claude.ai/code) if you haven't already:
   ```bash
   npm install -g @anthropic-ai/claude-code
   ```

2. Log in to Claude Code:
   ```bash
   claude
   ```
   
3. Launch Claude Monitor — it will read your credentials automatically

## How It Works

Claude Monitor reads your Claude Code OAuth credentials and queries the usage API endpoint at `api.anthropic.com/api/oauth/usage`. Tokens are persisted locally in `~/.claudemonitor/` for multi-account support.

**Note:** This uses an undocumented API that could change at any time. The app will gracefully handle API changes but may stop working if Anthropic modifies the endpoint.

## Privacy

- Your credentials never leave your machine
- No analytics or telemetry
- No data sent anywhere except Anthropic's API
- Open source - verify the code yourself

## Status Colours

| Normal | Warning | Critical |
|--------|---------|----------|
| 🟢 30% | 🟡 75% | 🔴 95% |

## Troubleshooting

### "Not logged in to Claude Code"

Run `claude` in Terminal and complete the login flow.

### App doesn't appear in menubar

Check if the app is running in Activity Monitor. Try quitting and reopening.

### Usage shows wrong values

Click the refresh button (↻) in the dropdown. If still wrong, your Claude Code session may have expired - run `claude` again.

## Contributing

PRs welcome! Please open an issue first to discuss major changes.

## License

MIT License - do whatever you want with it.

## What's Changed (Fork)

This fork adds the following improvements over the original:

- **Multi-account support** — monitor multiple Claude accounts with an accordion UI
- **File-based token persistence** — tokens stored in `~/.claudemonitor/` instead of Keychain for reliability
- **Compact UI redesign** — smaller usage rows, compressed footer, and decomposed view architecture
- **Concurrent refresh** — all accounts refresh in parallel via TaskGroup
- **SF Symbol status bar icon** — replaces text-based menubar indicator
- **Improved polling** — 60-second refresh interval with retry and staleness detection

## Disclaimer

This is an unofficial tool not affiliated with Anthropic. It uses an undocumented API that may change without notice.

---

Originally created by [@richhickson](https://x.com/richhickson) | Maintained by [@owenjohnson](https://github.com/owenjohnson)
