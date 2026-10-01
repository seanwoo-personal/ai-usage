# Change review

Owner: @seanwoo-personal. Run these passes separately and record evidence in the PR.
A checklist is review guidance; it does not prove an independent reviewer approved a change.

1. **Contract and impact:** identify the affected row in [architecture](architecture.md), changed consumers and invariants.
2. **Failure and verification:** inspect the diff against failure cases, execute relevant checks, and record omissions.
3. **Independent review:** a reviewer other than the author examines the diff and results. If unavailable, mark pending.

| Change | Required evidence |
|---|---|
| Swift logic | `make check`; regression assertion fails before a bug fix |
| Login/auth | Fake credential/origin checks; no tokens or real account data in logs |
| Installer/updater | Isolated installation cases, rollback preservation; no production installation during tests |
| UI/copy | Korean and English copy; manual visual evidence |
| Docs/tooling | `make docs`; link coverage and validator negative fixtures |
| Distribution | [release checklist](release-and-operations.md), including separate manual checks |

Required status checks and independent approval must be configured in repository settings by the maintainer.
The checked-in workflow alone does not enforce a merge gate. The workflow job is named `validate`.
A new source area must be linked from the entry guide and covered by an appropriate test path.
