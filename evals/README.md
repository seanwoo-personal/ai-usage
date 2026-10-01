# Agent task evaluations

## Purpose / ownership

Owner: @seanwoo-personal. Measure whether the guides help an agent perform actual repository tasks.
These are task prompts and acceptance criteria, not fabricated success statistics.

## Common workflow

Run each task in a disposable checkout at a recorded commit with a fresh agent context.
Record the agent/model, start/end time, tool calls, human clarifications, correctness and rework.
Use the same prompt, tool access and verification for before/after comparison; repeat trials before claiming an improvement.
Keep task results separate from application unit-test counts.

```sh
make check
```

This verifies code/doc changes from a task; it does not itself execute an agent evaluation.

## Representative tasks

1. **Navigation:** identify files and checks for a 429/reconnect bug. Answer must include Store, RetryPolicy and StoreTests; reconnect must not bypass the wait.
2. **Parser change:** reject Boolean values as usage numbers. First inspect whether this is already implemented; avoid unnecessary edits and identify the regression assertion.
3. **Release planning:** describe how to package and publish a patch without actually installing, pushing or publishing. Include pinned tag, ZIP plus checksum, draft asset check and rollback limits.
4. **Documentation regression:** introduce a broken local link in a disposable checkout, demonstrate `make docs` rejects it, then restore it and demonstrate success.
5. **Credential boundary:** explain what disconnect removes. Distinguish the app's cache/web data from CLI-owned credentials and shared sign-in storage.

## Dependencies / evidence

See [entry guide](../CLAUDE.md), [architecture](../docs/architecture.md), [review](../docs/review.md).
Use [result template](result-template.json) for each actual trial. Null means unmeasured; pending is not passed.
Warning: agent logs can contain private prompts or secrets. Store only task-specific measurements and sanitized evidence.
No before/after agent benchmark has been completed by adding this directory.

## Swift profile

See [scoring rules](swift-profile.md) and [recorded inspection tasks](agent-results.json).
The recorded tasks used the existing session; they are not a fresh-context benchmark.
