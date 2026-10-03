<p align="center">
  <img src="docs/images/icon.png" width="128" alt="AI Usage icon">
</p>

<h1 align="center">AI Usage</h1>

<p align="center">
  See how much Claude and Codex you have left, and when it resets, right in your Mac's menu bar.
</p>

<p align="center">
  <a href="https://github.com/seanwoo-personal/ai-usage/releases/latest"><img src="https://img.shields.io/github/v/release/seanwoo-personal/ai-usage?style=flat-square&color=0a0a0c" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-0a0a0c?style=flat-square" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%26%20Intel-universal-0a0a0c?style=flat-square" alt="Universal">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square" alt="MIT License"></a>
</p>

<p align="center">
  English · <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <img src="docs/images/menubar.png" width="420" alt="AI Usage in the menu bar, light and dark">
</p>

<p align="center">
  <img src="docs/images/popover.png" width="720" alt="AI Usage popover with 5-hour and weekly limits, light and dark">
</p>

## Features

- **At a glance**: each service shows time until reset on top (`5d 18h`) and what's left below (`72%`).
- **Claude and Codex**: the 5-hour session limit, the weekly limit, and per-model weekly limits when your plan has them.
- **Pace marker**: a tick on each bar shows where you'd be if you spread usage evenly; ahead of it means you have room.
- **Two ways to connect**: log in to claude.ai / chatgpt.com inside the app, or reuse the Claude Code / Codex CLI login already on your Mac.
- **Clear when something's wrong**: every problem comes with one sentence and one button (log in again, try again). Last known values stay visible.
- **Respects rate limits**: honours the server's `Retry-After` and never hammers the API.
- **Updates itself**: checks once a day; one click installs the new version with the same checks as a fresh install.
- **System status too (optional)**: CPU, RAM, SSD and network speed in a second menu bar item, measured the same way as [Stats](https://github.com/exelban/stats). Off by default.
- **For AI tools too**: a read-only `status` command and MCP server, so an AI can watch several Macs over SSH. See the [user guide](docs/user-guide.md#use-with-ai-tools-and-scripts-mcp).
- **Small and private**: no account, no analytics, no server of its own.

## Install and use

Requires macOS 13+ (Apple Silicon or Intel). Install, update, uninstall, privacy details and troubleshooting:
[English user guide](docs/user-guide.md) · [한국어 사용 안내](docs/user-guide.ko.md).

> AI Usage uses ad-hoc signing. The installer verifies integrity, not developer identity.
> Read the installation notes in the guide before installing.

## Build and contribute

From the repository root, with Swift 5.9+ Command Line Tools and Python 3.9+:

```sh
make check
```

For packaging, use `VERSION=0.0.0 make package`. Release publishing is a separate workflow.
See [contributing](CONTRIBUTING.md), [agent guide](CLAUDE.md),
[architecture and dependencies](docs/architecture.md), [review](docs/review.md), and [release history](CHANGELOG.md).

## License

[MIT](LICENSE) © 2026 Sean Woo. Independent project; not affiliated with Anthropic or OpenAI.
Claude and ChatGPT branding belongs to its respective owners; icon attribution is in the [user guide](docs/user-guide.md).
System measurements follow [Stats](https://github.com/exelban/stats) (MIT).

Readiness: [Swift-specific rules and limitations](evals/swift-profile.md), [original and adapted scores](evals/readiness-score.json).
