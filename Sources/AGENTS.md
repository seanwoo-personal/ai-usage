# App source guide

## Purpose / ownership

This directory owns the macOS app. Start at [main.swift](AIUsage/main.swift), which wires settings, store and UI.

## Common modification patterns

| Change | Start here | Verify |
|---|---|---|
| Fetch, reconnect, retry | [Store.swift](AIUsage/Store.swift), [Backend.swift](AIUsage/Backend.swift) | StoreTests |
| Usage parsing | [Models.swift](AIUsage/Models.swift), [CodexProvider.swift](AIUsage/CodexProvider.swift), [ClaudeProvider.swift](AIUsage/ClaudeProvider.swift) | SelfTest, Regression |
| Login origin / web flow | [WebAccount.swift](AIUsage/WebAccount.swift) | OriginTests, StoreTests; manual web-login check |
| Menu / copy | [PopoverView.swift](AIUsage/PopoverView.swift), [StatusImage.swift](AIUsage/StatusImage.swift), [L10n.swift](AIUsage/L10n.swift) | SelfTest; both-language visual check |
| System status (CPU · RAM · SSD · network) | [SystemMonitor.swift](AIUsage/SystemMonitor.swift), [SystemDetails.swift](AIUsage/SystemDetails.swift), [SystemDetailView.swift](AIUsage/SystemDetailView.swift) | SystemTests, crash probes; `--render-details <dir>` off-screen check |
| Update / startup | [Updater.swift](AIUsage/Updater.swift), [LoginItem.swift](AIUsage/LoginItem.swift) | UpdaterTests, installer tests, startup checks |

Run from repository root after a code change:

```sh
make check
```

## Non-obvious constraints

Warning: only the current connection/request generation may publish a response. Reconnect must not bypass Retry-After.
CLI credentials belong to the CLI; never refresh or erase them. Use fake inputs for tests.
A login redirect provider is not a trusted origin for usage fetching. Keep popup windows separate.
Set a status-item image only when its content or light/dark changes: macOS re-reports the appearance after
every image change, so redrawing on each report loops and keeps a CPU core busy.

## Dependencies and impact

Store depends on UsageBackend, settings, clock and scheduler. LiveBackend selects web or CLI providers.
Providers return Models; Store publishes snapshots to UI. The updater calls the bundled installer.
See [architecture](../docs/architecture.md), [tests](../Tests/AGENTS.md), [decisions](../docs/decisions/README.md).
