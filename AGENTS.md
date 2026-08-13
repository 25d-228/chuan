# Repository Contract

## Precedence

Follow issue requirements first, then the nearest nested `AGENTS.md`, this root
contract, and finally the surrounding code.

## Scope and implementation

- Build only what the issue requires. Avoid unrelated cleanup and speculative
  abstractions, options, hooks, wrappers, or dependencies.
- Match the surrounding code's formatting and structure. Use clear names,
  cohesive code, direct functions, useful why-comments, and explicit errors.
- Do not add a dependency without approval.

## Tests and validation

- Add a small number of behavior-focused tests for realistic regression risks.
  Never weaken a test to make it pass.
- Use repository-native headless validation. CI is the full gate.

## Machine safety

- Do not launch, install, or interact with applications. Do not use GUI
  automation, simulated input, persistent services, or local platform-integration
  runs already covered by CI.
- Report required human verification; do not perform it or create long manual
  checklists.

## Pull requests

- Use one issue and one pull request with exactly one `Fixes #N` in the pull-request
  description. Address requested changes on the same branch.

## Executor responses

Keep routine messages concise. Put a completion or blocker handoff in one fenced
block beginning with `EXECUTOR → ORCHESTRATOR` and include the repository, issue
and pull-request numbers, branch, latest commit, CI state, unresolved feedback,
uncovered requirements, blocking human verification, deferred visual verification,
queue state, and any blocker.
