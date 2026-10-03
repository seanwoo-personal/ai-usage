# Changelog

All notable changes to AI Usage. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.5.1] - 2026-10-03

### Added
- `account_key` in saved status and MCP results: a one-way label (SHA-256 of the service's account or organization
  ID) so a tool watching several Macs can tell when they share a Claude or Codex account and show it once. Same
  account → same label on every Mac, web or CLI. The ID itself is never stored or shown. For a Claude CLI login the
  organization is read from Claude Code's settings file (`~/.claude.json`, `oauthAccount.organizationUuid` only).

### Security
- Process names (chosen by any running program) are cleaned before they're shown or returned over MCP: one line,
  no control or invisible formatting characters, at most 64 characters. The MCP server also tells AI clients that
  names and other reported text are data, never instructions.

## [1.5.0] - 2026-10-03

### Added
- Read this Mac's status from scripts and AI tools: the app saves CPU, memory, disk, network (with levels and
  two minutes of history) and Claude/Codex usage every 5 seconds to a file only you can read, and its executable
  has read-only commands — `status` (`--json`), `top cpu|memory|disk` and `mcp`, an MCP server on stdin/stdout.
  Run it over SSH to watch several Macs; nothing listens on the network. No tokens or account details are included.
  On by default; Settings → "Save this Mac's status for other AI tools".

### Changed
- The system monitor keeps running every 5 seconds when no system item is shown, so headless Macs still have
  current status (every second while an item is shown).

## [1.4.1] - 2026-10-03

### Fixed
- Installing or updating failed on Macs without the Xcode command line developer tools ("can't run on this Mac"),
  and could prompt to install them. The CPU-type check now uses the built-in `file` command instead of `lipo`.
  Affected the one-line install and in-app updates since 1.2.0.

## [1.4.0] - 2026-10-03

### Added
- Click CPU, RAM, SSD or network in the menu bar for details, like Stats: a two-minute chart, a breakdown
  (CPU system/user/idle, per-core load, load average and uptime; RAM app/wired/compressed/cached/free, swap and
  memory pressure; disk read/write speed, free space and totals; network interface, local IP and totals) and the
  busiest processes. Process lists are read only while a detail popover is open.
- CPU, RAM and SSD turn yellow or red in the menu bar when the Mac is under strain: CPU by its 5-second average
  (70% / 90%), RAM by free memory as macOS measures it for memory pressure (under 20% / 10%), SSD by space used
  (90% / 95%). On by default; can be turned off in Settings.

### Changed
- Each system metric is now its own menu bar item, so it can be clicked and ⌘-dragged on its own.
- System readings refresh every second (was 2 seconds), matching Stats.

### Fixed
- The menu bar could redraw itself continuously and keep a CPU core busy: changing a status image made macOS
  report the menu bar appearance again, which triggered another redraw. It now redraws only when light/dark
  actually changes or the shown values change.

## [1.3.0] - 2026-10-03

### Added
- Optional system section in the menu bar: CPU, RAM, SSD and network speed, refreshed every 2 seconds and
  calculated the same way as [Stats](https://github.com/exelban/stats). Off by default; turn it on in Settings and
  pick which metrics to show. Uses only built-in macOS interfaces (no helper tool, admin rights or permissions).

### Fixed
- Menu bar text looked faded on translucent (light-tinted) menu bars. It is now drawn in solid white or black to
  match the menu bar, and redrawn when the menu bar switches between light and dark.

## [1.2.2] - 2026-10-02

### Changed
- Optimizations. / 최적화.

## [1.2.1] - 2026-10-01

### Fixed
- In-app update left the previous version running: the installer now also finds and quits the app that launched it,
  using a quit signal instead of AppleScript (no "control another app" permission prompt).

### Changed
- The update banner fits on one line, with **What's new** and **Update** on the right.

## [1.2.0] - 2026-10-01

### Added
- Automatic updates: a daily check of the latest GitHub release, installed with the bundled installer after the same
  checks as a fresh install. Can be turned off in Settings.

### Fixed
- Overlapping refreshes could show an older value after a newer one. Requests are now one at a time per service,
  numbered, and tied to the current connection; answers from before a disconnect or reconnect are ignored.
- A login window that finished after you disconnected could reconnect the service.
- A new web login could start while the previous logout was still erasing data.
- The server's wait after HTTP 429 was bypassed by the menu, timer, refresh button or reconnect. `Retry-After`
  (seconds or HTTP date) is now honoured on every path.
- Unusual values from a server (NaN, infinity, out-of-range numbers, `true`, invalid dates) could crash the app.
- "Both" in the menu bar invented a weekly value when only a 5-hour window existed.
- Codex log fallback picked a recently touched file over the newest event, failed when the read window started inside
  a multi-byte character, missed resumed conversations in older folders, and accepted events with a broken timestamp.
- After switching accounts in Claude Code, the previous account's cached token could still be used.

### Security
- Login and usage checks require the exact HTTPS origin (no look-alike hosts, other ports, user info or plain HTTP).
  The login window says whether you are on the service, a sign-in provider, or another site.
- Web Inspector is enabled only in development builds.
- Installer: pins the release, verifies SHA-256, archive paths, bundle ID, executable, architecture, minimum macOS and
  signature integrity, stages next to the destination, swaps last and rolls back on failure; one installer at a time.

### Changed
- Privacy wording now matches what the app does (tokens are sent to the official services, never to the developer).

## [1.1.2] - 2026-10-01

### Fixed
- "Open at login" could register a temporary, build or disk-image copy, leaving a broken login item. It now only
  turns on for a copy in /Applications or ~/Applications, and re-registers the current location at launch.

### Changed
- The bundle ID is fixed to `com.sean.aiusage`.

## [1.1.1] - 2026-09-28

### Security
- Hardened Runtime enabled for ad-hoc signed builds. Releases are immutable once published.

## [1.1.0] - 2026-09-28

### Added
- First public release: menu bar usage for Claude and Codex, web or CLI login, first-run guide, one-line installer.

[Unreleased]: https://github.com/seanwoo-personal/ai-usage/compare/v1.5.1...HEAD
[1.5.1]: https://github.com/seanwoo-personal/ai-usage/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/seanwoo-personal/ai-usage/compare/v1.4.1...v1.5.0
[1.4.1]: https://github.com/seanwoo-personal/ai-usage/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/seanwoo-personal/ai-usage/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/seanwoo-personal/ai-usage/compare/v1.2.2...v1.3.0
[1.2.2]: https://github.com/seanwoo-personal/ai-usage/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/seanwoo-personal/ai-usage/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/seanwoo-personal/ai-usage/compare/v1.1.2...v1.2.0
[1.1.2]: https://github.com/seanwoo-personal/ai-usage/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/seanwoo-personal/ai-usage/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/seanwoo-personal/ai-usage/releases/tag/v1.1.0
