# Test guide

## Purpose / ownership

This directory owns isolated app checks, not live-account or UI end-to-end tests.
[SelfTest](selftest.swift) is the runner; [Regression](regression.swift) contains crash probes and log fixtures;
[store_tests.swift](store_tests.swift) contains StoreTests, CredentialTests, OriginTests and UpdaterTests.

## Common modification patterns

For a bug fix, add an assertion that fails before the fix. For crash-prone input, add a child-process probe.
Use FakeBackend and FakeTime for request ordering; use AppSettings.forTesting for temporary settings.
Codex log cases must create synthetic files in a temporary directory.

From repository root:

```sh
make test
```

The runner must report ALL PASSED and installer 0 failed. Compiler warnings are surfaced; review them.

## Non-obvious constraints

Warning: no real Keychain, user settings, CLI login files, network or login windows in automated tests.
Do not interpret one aggregate assertion over randomized operations as thousands of independent passed tests.
The installer suite creates fake signed apps and replaces only a temporary install directory.

## Dependencies and impact

The shell runner compiles app sources except the production main entry, then runs these tests and the installer suite.
See [runner](../scripts/selftest.sh), [installer tests](../scripts/test-install.sh),
[architecture](../docs/architecture.md), [review](../docs/review.md).
