# Contributing

Thanks for helping. AI Usage is a small app, so the bar is: keep it small, private and predictable.

## Build and test

You need the Xcode Command Line Tools (Swift 5.9+); Xcode itself isn't required.

```bash
./scripts/selftest.sh                  # must end with ALL PASSED and "installer: … 0 failed"
VERSION=0.0.0 ./scripts/build-app.sh   # optional: build the app, ZIP and DMG into dist/
```

Tests must never touch real accounts or data: no Keychain, no `~/.codex`, no real settings, no network.
Use the fakes in `Tests/` (fake backend, clock and scheduler, `AppSettings.forTesting()`, temporary folders).
Inputs that could crash the app go into the probe list in `Tests/regression.swift`, which runs each in its own process.

## Pull requests

- One topic per pull request, with a short description of the user-visible change.
- Add a test that fails without your change when you fix a bug.
- Update `CHANGELOG.md` under **Unreleased**.
- UI text exists in Korean and English (`L.t("…", "…")`); please provide both, or ask in the PR.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/), short and in English:

```
fix(installer): quit the app that launched the update
feat(updater): check GitHub releases once a day
docs: add Korean README
```

Keep the subject under about 50 characters; put details in the body.
