# Contributing

Start a topic branch from current `main`. External contributors can push their
branch to a fork. Keep each pull request focused on one change.

Use Conventional Commits for commit subjects and PR titles, for example
`feat(inventory): show mounted volumes` or `fix(eject): reject stale confirmations`.
Use the PR title as the squash commit subject when merging.

Stage your changes and run the same checks used in CI from the root:

```sh
./scripts/check-repo main
swift test
./scripts/build-app
```

The check inspects the staged tree for files covered by the repository's ignore
rules, checks whitespace in changes since the named base and checks shell
syntax in the working tree. Use `.local/` for
plans, design notes and handoffs in any format.

In the PR, describe the behavior change and how you verified it. For drive
handling changes, include the macOS version, storage topology and observed
mount state. Redact device serials, UUIDs and personal paths from logs.

## Merging

Changes to `main` go through a pull request. Bring the branch up to date, pass
`Repository checks` and resolve review conversations before merging. Use a
merge commit or squash merge. A second maintainer's approval is optional.
