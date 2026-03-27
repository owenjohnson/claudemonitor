# Claude Monitor

<p align="center">
  <img src="Xnapper-2026-01-09-11.22.53.png" alt="Claude Monitor Screenshot" width="300">
</p>

A lightweight macOS menubar app that displays your Claude Code usage limits at a glance.

Originally built by [@richhickson](https://x.com/richhickson). Forked and maintained by [@owenjohnson](https://github.com/owenjohnson).

## Features

- 🔄 **Auto-refresh** every 2 minutes with retry logic
- 🚦 **Color-coded status** — Green (<70%), Orange (>=70%), Red (>=90%)
- ⏱️ **Time until reset** for both session and daily limits
- 📊 **Session & Daily limits** displayed together
- 👥 **Multi-account support** — monitor multiple Claude accounts simultaneously
- 🚀 **Launch at login** — optional auto-start via macOS Login Items
- 🔔 **Automatic update checks** — notifies you when a new release is available
- 🪶 **Lightweight** — Native Swift, minimal resources

## Requirements

- macOS 13.0 (Ventura) or later
- A long-lived OAuth token from your Claude account (see [Setup](#setup))

## Installation

### Download

1. Go to [Releases](../../releases)
2. Download `ClaudeMonitor.zip`
3. Unzip and drag `ClaudeMonitor.app` to your Applications folder
4. Open the app (you may need to right-click → Open the first time)

### Build from Source (Xcode)

```bash
git clone https://github.com/owenjohnson/claudemonitor.git
cd claudemonitor
open ClaudeMonitor.xcodeproj
```

Build with **⌘B** and run with **⌘R**.

### Build from Source (CLI)

```bash
git clone https://github.com/owenjohnson/claudemonitor.git
cd claudemonitor
./install.sh
```

This builds a Release configuration and installs `ClaudeMonitor.app` to `/Applications`.

## Setup

Claude Monitor requires a **long-lived OAuth token** with `user:inference` scope. This is different from the short-lived session tokens that Claude Code rotates automatically.

### 1. Get your OAuth token

1. Go to [console.anthropic.com](https://console.anthropic.com)
2. Navigate to **Settings** → **OAuth Applications**
3. Create a new OAuth token (or use an existing one) with the `user:inference` scope
4. Copy the token — it will look like `sk-ant-oaut01-...`

### 2. Add the token to the config file

Copy the included example template and fill in your token(s):

```bash
mkdir -p ~/.claudemonitor
cp claudeoauth.example.json ~/.claudemonitor/claudeoauth.json
```

Then edit `~/.claudemonitor/claudeoauth.json` with your real tokens. See [`claudeoauth.example.json`](claudeoauth.example.json) for the expected format.

**Single account (simple array):**
```json
["sk-ant-oaut01-your-token-here"]
```

**Multiple accounts (with labels):**
```json
[
  {"token": "sk-ant-oaut01-personal-token", "name": "Personal"},
  {"token": "sk-ant-oaut01-work-token", "name": "Work"}
]
```

### 3. Launch Claude Monitor

The app will read tokens from `~/.claudemonitor/claudeoauth.json` and start polling usage automatically.

> **Tip:** You can override the token file location by creating `~/.claudemonitor/config.json`:
> ```json
> {"tokenFile": "/path/to/your/tokens.json"}
> ```

## How It Works

Claude Monitor makes a minimal inference call (1 token, cheapest model) to the Anthropic Messages API and reads the rate-limit headers from the response to determine your current usage against session and daily limits. This repeats every 2 minutes.

**Note:** This relies on rate-limit headers returned by the Anthropic API, which could change without notice. The app handles API errors gracefully but may stop working if Anthropic modifies the response format.

## Privacy

- Your credentials never leave your machine
- No analytics or telemetry
- No data sent anywhere except Anthropic's API
- Open source — verify the code yourself

## Status Colors

| Color | Threshold | Meaning |
|-------|-----------|---------|
| 🟢 Green | < 70% | Normal usage |
| 🟠 Orange | >= 70% | Approaching limit |
| 🔴 Red | >= 90% | Near or at limit |

## Troubleshooting

### "No OAuth tokens found"

Make sure `~/.claudemonitor/claudeoauth.json` exists and contains valid tokens. The app will show the expected file path in the error message.

### App doesn't appear in menubar

Check if the app is running in Activity Monitor. Try quitting and reopening.

### Usage shows wrong values

Click the refresh button (↻) in the dropdown. If still wrong, your token may have expired — generate a new one from the Anthropic console.

## Contributing

PRs welcome! Please open an issue first to discuss major changes.

## License

MIT License — do whatever you want with it.

## What's Changed (Fork)

This fork adds the following improvements over the original:

- **Multi-account support** — monitor multiple Claude accounts with an accordion UI
- **File-based token persistence** — tokens stored in `~/.claudemonitor/` instead of Keychain for reliability
- **Compact UI redesign** — smaller usage rows, compressed footer, and decomposed view architecture
- **Concurrent refresh** — all accounts refresh in parallel via TaskGroup
- **SF Symbol status bar icon** — dynamic color indicator with usage percentage in the menubar

## Disclaimer

This is an unofficial tool not affiliated with Anthropic. It relies on undocumented API behavior that may change without notice.

---

Originally created by [@richhickson](https://x.com/richhickson) | Maintained by [@owenjohnson](https://github.com/owenjohnson)
