# Bitbucket Cloud helpers

These optional scripts add review-time automation for a home whose projects live on bitbucket.org.
Firstmate's own Bitbucket support does not need them.
`bin/fm-pr-check.sh` registers a Bitbucket pull request and arms its merge poll, and `bin/fm-pr-merge.sh` merges it only when its builds are green.
Registering the project with `forge=bitbucket` (see [`docs/configuration.md`](../../docs/configuration.md) "Forge selection") makes ship workers use twg for their pull requests.

Every script reads twg's JSON output and needs `twg` (logged in to Bitbucket), `jq`, and `git` on PATH.
`bb-park.sh` also needs `python3`.
None of them hardcodes a home, workspace, repository, or account.
The home comes from `FM_HOME`, which must be set.
Everything else is passed as flags, or through the environment variables each script's header lists.
Each script's header owns its exact options, and `bb-watch-install.sh --help` and `renovate-approve.sh --help` print theirs.

## Scripts

- `bb-watch-install.sh <task-id> <pr-number> --workspace <ws> --repo <repo>` arms a notify-only watch on a task's pull request.
  It first runs `bin/fm-pr-check.sh`, unless `--no-pr-check` is passed.
  It then writes `state/<task-id>-bbwatch.check.sh` and binds it with `bin/fm-check-register.sh`, so the watcher polls it on every check sweep.
- `bb-watch-poll.sh` is the poll that check runs.
  It reports new comments, a new conflict, a parked or resumed worker, green builds, and a declined pull request.
  A failed build goes to the worker first, through `bin/fm-send.sh`.
  It retires its own check once the pull request closes or the task is cleaned up.
- `bb-conflict-check.sh` reports when the source branch newly conflicts with its destination.
  It works in a scratch clone under `state/.cc/<task-id>` and never touches the project's work tree.
- `bb-park.sh` stops the agent of a green pull request that has been idle for `--park-days` weekdays, and relaunches it when new activity or a failed build arrives.
  Parking keeps the branch, the local copy, and the pull request.
- `renovate-approve.sh` approves a dependency bot's open pull requests when every build at their head is green.
  It is a dry run unless you pass `--apply`.

## Wiring a home

Call the scripts by their path in this checkout, or symlink them into the home's `config/`.
They always find their sibling scripts and the firstmate `bin/` beside them, wherever they are called from.

```sh
FM_HOME=/path/to/home contrib/bitbucket/bb-watch-install.sh my-task 1234 \
  --workspace my-workspace --repo my-repo \
  --ignore-author 'Review Bot' --ignore-prefix '[AI - Firstmate]'
```

The CI verdict defaults to the build statuses at the pull request's head.
A home that judges builds differently passes `--ci-cmd <path>`.
That command prints `<GREEN|FAILED|RUNNING|NONE> <head-sha>` as its first line, and `bb-watch-poll.sh`'s header owns that contract.
A home with more parking conditions passes `--ready-cmd <path>`, which must exit 0 before a worker is parked.
