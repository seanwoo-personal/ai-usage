# Tooling guide

## Purpose / ownership

This directory owns local validation and release packaging. [selftest.sh](selftest.sh) runs isolated tests;
[build-app.sh](build-app.sh) packages the app; [install.sh](install.sh) validates and swaps releases;
[check_docs.py](check_docs.py) validates tracked Markdown links and navigation coverage.

## Common modification patterns

Installer changes require a failure fixture in [test-install.sh](test-install.sh).
Documentation-checker changes require positive and negative fixtures in [test_check_docs.py](test_check_docs.py).
Run from repository root:

```sh
make docs
make test
```

Packaging is separate: `VERSION=0.0.0 make package` writes disposable artifacts; it does not publish them.

## Non-obvious constraints

Warning: preserve fixed bundle ID, pinned release, checksum and signature checks, staged swap and rollback.
Test overrides are accepted only in test mode. Never use the production installer as an automated test.
Do not run release or real installation commands during an audit.

## Dependencies and impact

build-app.sh copies install.sh into the app. Updater runs that bundled copy; installer changes affect both installation paths.
See [architecture](../docs/architecture.md), [operations](../docs/release-and-operations.md),
[decisions](../docs/decisions/README.md), [contributing](../CONTRIBUTING.md).
