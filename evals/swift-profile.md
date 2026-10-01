# Swift equivalence profile v1

This is a project-specific adaptation, not the upstream rubric or an official certification.
Always report the original score alongside this score. Neither score proves CI success,
independent review, live-login reliability or improved agent productivity.

## Equivalent evidence (maximum five additional points)

| Original condition | Swift equivalent | Points |
|---|---|---|
| JavaScript workspace file | SwiftPM manifest successfully loads, every target has a source directory, and architecture map exists | D: 2 |
| Node scripts or Husky | `make check` resolves to documentation checks, Swift build/type checking and isolated app tests | E: 1 |
| Husky pre-push/pre-commit | Executable native Git pre-push invokes docs checks and has an explicit installation command | F: 2 |

All other original categories remain unchanged. Missing equivalents earn no credit;
originally credited conditions are never counted twice. A native hook is available,
not automatically installed. Use `make hooks` only when opting in to the repository hook.

## Reproduce

Run [the adapter](../scripts/score_swift_readiness.py) with `--original-scorer` pointing to
an authorized, unmodified local copy of the upstream v2 scorer, and `--output` pointing
to the desired JSON report. It executes the original scorer first; no saved score is trusted.
The upstream scorer is not redistributed here. Run `make docs` for adapter regression tests.
See [score snapshot](readiness-score.json) and [task evidence](agent-results.json).

## Task evidence limits

The current records are three source-inspection tasks performed by the same Codex session
that edited the guides. They are self-reviewed, not independent fresh-context trials.
No timing, productivity improvement or before/after benchmark is claimed.
The upstream G score only detects the result filename; it does not validate these limitations.
