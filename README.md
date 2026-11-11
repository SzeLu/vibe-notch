<div align="center">
  <a href="README.zh-CN.md">🇨🇳 简体中文</a>
</div>

<div align="center">
  <img src="VibeNotch/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Logo" width="100" height="100">
  <h3 align="center">Vibe Notch (previously Claude Island)</h3>
  <p align="center">
    A macOS menu bar app that brings Dynamic Island-style notifications to your coding agents — Claude Code, WorkBuddy, and OpenCode.
    <br />
    <br />
    <a href="https://github.com/farouqaldori/vibe-notch/releases/latest" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/github/v/release/farouqaldori/vibe-notch?style=rounded&color=white&labelColor=000000&label=release" alt="Release Version" />
    </a>
    <a href="#" target="_blank" rel="noopener noreferrer">
      <img alt="GitHub Downloads" src="https://img.shields.io/github/downloads/farouqaldori/vibe-notch/total?style=rounded&color=white&labelColor=000000">
    </a>
  </p>
</div>

> **🟢 Actively maintained**
>
> Launched v1.2 in December 2025, then took a 4-month break. v1.3 (April 2026) works through the backlog of contributor PRs and bug reports and kicks off a regular cadence again. Open PRs and issues are being reviewed — thanks for your patience.

## Features

- **Notch UI** — Animated overlay that expands from the MacBook notch, with a built-in settings menu right inside the panel. Click the notch to open it; hovering only shows a subtle shadow and does **not** auto-expand.
- **Multi-Agent Monitoring** — Track live sessions from Claude Code, WorkBuddy, and OpenCode side by side, each tagged with a short badge (`WB`, `OC`).
- **Live Session Monitoring** — See every running agent session, its status (processing / waiting for input / completed), model, and working directory in real time.
- **Permission Approvals** — Approve or deny Claude Code tool executions directly from the notch — no need to switch back to the terminal.
- **Jump to Terminal** — Every session has a jump button that brings the terminal window/tab running that agent to the front. Terminal.app and iTerm2 are matched exactly by TTY, WezTerm by its CLI pane (TTY / cwd), and other terminals (Paseo, kitty, Warp, Ghostty, VS Code, …) by activating the app and raising the window whose title matches the project. tmux + yabai keeps its exact pane switching.
- **Chat History** — View the full conversation with markdown rendering for Claude Code sessions.
- **Shell Panel** — A read-only view of the shell commands your agents have run (command, output, status), scoped per session or across all sessions.
- **Monitor Panel** — Track background / detached tasks agents spawn, with a notch bounce and sound when a task finishes.
- **Multi-Display** — Automatically prefer the built-in display, or pin the notch to a specific screen; works correctly with displays of different sizes and arrangements.
- **Auto-Setup** — Claude Code hooks install automatically on first launch.
- **Polished Details** — Launch at login, selectable completion sounds, and built-in auto-updates via Sparkle.

## Requirements

- macOS 15.6+
- At least one supported coding agent:
  - **Claude Code** CLI (full support: hooks, permissions, chat history)
  - **WorkBuddy** (session monitoring)
  - **OpenCode** (session monitoring)

## Install

Download the latest release, or build from source:

```bash
xcodebuild -scheme VibeNotch -configuration Release build
```

## How It Works

Each supported agent is an independent provider unit. Vibe Notch detects their activity using whatever data source each tool exposes, then normalizes everything into a single session model that the notch UI renders.

| Agent | Detection | Capabilities |
|-------|-----------|--------------|
| **Claude Code** | Hooks installed into `~/.claude/hooks/` push state over a Unix socket | Sessions, permission approvals, chat history, shell & background tasks |
| **WorkBuddy** | Polls `~/.workbuddy-ai/sessions/*.json` heartbeats and reads `~/.workbuddy-ai/workbuddy.db` (read-only) | Sessions, shell & background tasks |
| **OpenCode** | Polls `~/.local/share/opencode/opencode.db` (read-only; override with `OPENCODE_DATA_DIR`) | Sessions, shell & background tasks |

When Claude Code needs permission to run a tool, the notch expands with approve/deny buttons. Polled agents (WorkBuddy, OpenCode) are discovered every few seconds and their status is derived from the agent's own database and transcript activity.

## Scripts

The `scripts/` folder contains helper scripts for building, signing, and releasing the app. All scripts are run from the project root and assume you have Xcode command-line tools and the required CLIs installed.

> **Note:** The root-level `release-build.sh` is a thin one-line wrapper around `xcodebuild -scheme VibeNotch -configuration Release build`. It only performs a local compile (output lands in Xcode's DerivedData) and does **not** produce a distributable `.app`/DMG. For the full release pipeline (archive, notarize, package, publish), use the `scripts/` helpers below instead.

### `build.sh` — Build a release archive

Archives and exports a signed, hardened `Vibe Notch.app` using `xcodebuild`.

```bash
./scripts/build.sh
```

- Cleans and recreates `build/`, then runs `xcodebuild archive` (Release, hardened runtime, automatic signing).
- Exports the archive to `build/export/Vibe Notch.app` using a generated `ExportOptions.plist` (`developer-id` method).
- Requires `xcpretty` (optional — falls back to raw output if missing).
- **Output:** `build/export/Vibe Notch.app`

### `generate-keys.sh` — Generate Sparkle EdDSA keys

Generates the EdDSA key pair used to sign Sparkle auto-update feeds. **Run this once and keep the private key secure.**

```bash
./scripts/generate-keys.sh
```

- Locates Sparkle's `generate_keys` tool (from an Xcode SPM build or manual install).
- Writes the private key to `.sparkle-keys/eddsa_private_key` (chmod `600`) and stores a copy in your macOS Keychain.
- Prints the **public key** — add it to `Info.plist` as `SUPublicEDKey`.
- Auto-adds `.sparkle-keys/` to `.gitignore` so keys are never committed.
- Regenerating keys will break auto-updates for existing users, so it prompts for confirmation if keys already exist.

### `create-release.sh` — Notarize, package, and publish

Full release pipeline: notarize the app, build a DMG, sign it for Sparkle, generate the appcast, publish a GitHub release, and update the website.

```bash
./scripts/create-release.sh
```

What it does, step by step:

1. **Notarize** the app via `notarytool` (keychain profile `VibeNotch`). Prompts to skip if no credentials are set up.
2. **Create a DMG** — uses `create-dmg` if available, otherwise `hdiutil`.
3. **Notarize** the DMG.
4. **Sign for Sparkle** and generate `appcast.xml` (requires `generate-keys.sh` output and the Sparkle tools from a prior Xcode build).
5. **Create a GitHub release** (`gh`) tagged `v<VERSION>` and upload the DMG.
6. **Update the website** (Cloudflare Pages via `wrangler`) and `appcast.xml`.

Prerequisites:

- Run `build.sh` first so `build/export/Vibe Notch.app` exists.
- Run `generate-keys.sh` first for Sparkle signing.
- Set up the notarization keychain profile:
  ```bash
  xcrun notarytool store-credentials "VibeNotch" \
      --apple-id "your@email.com" \
      --team-id "2DKS5U9LV4" \
      --password "xxxx-xxxx-xxxx-xxxx"
  ```
- `gh` CLI (for the GitHub release) and `wrangler` (for the website deploy) are optional but recommended.
- The GitHub repo and website paths are configured at the top of the script (`GITHUB_REPO`, `WEBSITE_DIR`).

## Analytics

Vibe Notch uses Mixpanel to collect anonymous usage data:

- **App Launched** — App version, build number, macOS version
- **Session Started** — When a new agent session is detected

No personal data or conversation content is collected.

## License

Apache 2.0
