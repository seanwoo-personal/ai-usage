# Design decisions

## Purpose / ownership

Maintainer: @seanwoo-personal. These records explain existing constraints, not new product policy.

## Common changes

When changing an invariant, update its decision record and affected tests in the same PR.
Use `make docs` from the repository root to validate links.

## Dependencies / reasons

- [Stable app identity](identity.md): packaging, settings, WebKit and login item ownership.
- [Read-only CLI credentials](credentials.md): provider cache and disconnect boundaries.
- [One verified installer](updates.md): command-line installation and in-app update share checks.

Warning: a decision is not proof of a test run. Record actual validation separately in the PR.
See [architecture](../architecture.md) and [review](../review.md).
