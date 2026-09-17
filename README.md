# JFrog migration self-service tool

Self-service tool to migrate Artifactory repositories from a source
instance to a target instance using JFrog Data Transfer
(`jf rt transfer-files`), implemented as shell scripts run by GitHub
Actions. Queueing is native GitHub Actions concurrency control; state is
tracked in JSON files committed back into this repo.

## Status

Design / early implementation. See `docs/design.md` for the full flow,
open decisions, and rationale.

## High-level flow

1. **One-time, manual:** Data Transfer plugin installed on the source VM
   (not checked or managed by this tool).
2. User triggers the `Migrate repo` workflow via `workflow_dispatch`,
   giving a repo name and an environment name (must exist in
   `config/environments.yaml`). A GitHub issue-based trigger is planned
   next — see docs/design.md.
3. Workflow runs `jf rt ping` against source and target.
4. Workflow checks whether the repo exists in target; if not, creates it
   from an allowlisted subset of the source repo's config.
5. GitHub's native `concurrency:` group (`migrate-<env>`) queues the run
   if another migration for the same environment is already in progress
   — no custom lock/queue file needed.
6. Workflow runs `jf rt transfer-files`, polling its output and
   committing progress into `state/<job_id>.json` periodically.
7. On command exit:
   - Non-zero exit → job marked `failed`, error tail captured in state.
   - Zero exit → job marked `completed`. File count and total size are
     compared between source and target and logged into `diff_notes` —
     a diagnostic only, not a pass/fail gate (some drift is expected).

## Repo layout

```
.github/workflows/migrate.yml   workflow_dispatch trigger, orchestrates the steps below
.github/workflows/lint.yml      shellcheck on every script change
scripts/preflight.sh            jf rt ping source + target
scripts/repo_manager.sh         check/create target repo from allowlisted source config
scripts/migrate.sh              runs transfer-files, polls progress, logs diff_notes
scripts/state.sh                init/update/read state/<job_id>.json, commits + pushes
scripts/lib/common.sh           logging, env config loader, shared by all scripts
config/environments.yaml        source/target server ids, URLs, thresholds (no secrets)
state/                          committed per-job state files
docs/                           design notes, decisions, open questions
```

## Requirements

- GitHub Actions with `contents: write` permission on this repo (needed
  for the workflow to commit state back)
- Repo secrets: `SOURCE_ACCESS_TOKEN`, `TARGET_ACCESS_TOKEN`
- `jf` CLI, `jq`, `yq` — installed by the workflow itself, no local setup
  needed to run a migration

## Running a migration

1. Fill in `config/environments.yaml` with your source/target server
   details (commit it — no secrets in this file).
2. Add `SOURCE_ACCESS_TOKEN` / `TARGET_ACCESS_TOKEN` under
   Settings > Secrets and variables > Actions.
3. Actions tab → `Migrate repo` → Run workflow → enter repo name and env.

## Known limitations (see docs/design.md for detail)

- Plugin installation on the source VM is manual and not verified by
  this tool.
- Completion is determined by `jf rt transfer-files` exit status;
  file count/size differences are logged but do not block completion.
- Small-repo batching across separate requests isn't implemented —
  GitHub's native queueing handles one-at-a-time ordering, but doesn't
  combine multiple small repos into a single transfer job.
- The progress-parsing regex in `migrate.sh` assumes a particular
  `jf rt transfer-files` output shape — verify it against your installed
  CLI version and adjust if the JSON progress line format differs.
