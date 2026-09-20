# JFrog migration self-service tool

Self-service tool to migrate Artifactory repositories from a source
instance to a target instance using JFrog Data Transfer
(`jf rt transfer-files`), implemented as shell scripts run by GitHub
Actions. Queueing is native GitHub Actions concurrency control; state is
tracked in JSON files committed back into this repo.

## Status

Design / early implementation. The scripts currently implement a single
pipeline (connectivity check → repo check/create → transfer). The
two-pipeline, batched design below is the agreed direction — see
`docs/design.md` for open decisions (batch thresholds, what triggers
Pipeline B) and rationale.

## High-level flow

**Pipeline A — pre-migration (runs per request)**

1. **One-time, manual:** Data Transfer plugin installed on the source VM
   (not checked or managed by this tool).
2. User requests a migration; the request is appended to a request log
   file.
3. Connectivity check: `jf rt ping` against `source-server` and
   `target-server`. If either is unreachable, reject and **alert
   DevOps** (infra issue, not something the requesting user can fix).
4. If the repo doesn't exist in source at all, reject and notify the
   user (this one's user-actionable).
5. Fetch artifact count + size from source, and append a row to a
   single tracking file: `repo, count, size, config_status=pending,
   migration_status=pending`.
6. Config-only transfer: if the repo doesn't exist in target, create it
   from source's config (`GET` source → `PUT` target). No data is moved
   in this step.
7. Flip `config_status` to `completed` in that same row.
   `migration_status` stays `pending` — Pipeline A never touches it
   again.

**Pipeline B — data migration (scheduled poll)**

8. Runs on a cron schedule (not triggered by Pipeline A directly).
   Filter the tracking file down to rows where `config_status =
   completed AND migration_status = pending`.
9. Grouping logic (still being tuned): batch those repos by count/size
   thresholds into a batch of 1, 3, or 5.
10. Check whether any row has `migration_status = in_progress`; if so,
    wait for the next scheduled poll rather than starting a second
    transfer concurrently.
11. Set the batch's rows to `migration_status = in_progress` and notify
    the team the migration has started.
12. Run `jf rt transfer-files` per repo in the batch.
13. On exit:
    - Non-zero → reset `migration_status` back to `pending` so the next
      poll retries it automatically, and **alert DevOps**.
    - Zero → run a diagnostic-only file count/size comparison between
      source and target (logged, never blocks completion), set
      `migration_status = completed`, and notify the team with the
      source-vs-target count/size.

## Repo layout

```
.github/workflows/migrate.yml   workflow_dispatch trigger, orchestrates the steps below
.github/workflows/lint.yml      shellcheck on every script change
scripts/repo_manager.sh         connectivity check, repo existence checks, config-only repo creation
scripts/migrate.sh              preMigration wait check, runs transfer-files, polls progress, logs diff_notes
scripts/state.sh                init/update/read state/<job_id>.json, commits + pushes
scripts/lib/common.sh           logging, env config loader, shared by all scripts
config/environments.yaml        source/target server ids, URLs, thresholds (no secrets)
state/                          committed per-job state files
docs/                           design notes, decisions, open questions
```

> **Not yet implemented in the scripts:** the request log file, the
> merged tracking file (`config_status`/`migration_status` columns and
> batching), the grouping logic, the scheduled poll trigger, the
> retry-to-pending behavior on failure, and the start/completion team
> notifications. Currently `repo_manager.sh` and `migrate.sh` run the
> single-pipeline version (connectivity → repo check/create → transfer,
> one repo per run). This README documents the two-pipeline design
> we're building toward — see `docs/design.md` for what's tracked as
> open (batch thresholds, retry-count cutoff for repeatedly failing
> repos, poll interval).

## Flow diagram

```mermaid
flowchart TD
    subgraph A[" "]
        direction TB
        A0[User requests migration] --> A1[Append to request log file]
        A1 --> A2{source-server & target-server reachable?}
        A2 -->|no| A2f[Reject: alert DevOps — infra issue]
        A2 -->|yes| A3{Repo exists in source?}
        A3 -->|no| A3f[Reject: notify user]
        A3 -->|yes| A4[Fetch artifact count + size from source]
        A4 --> A5["Append row to tracking file<br/>repo, count, size, config_status=pending, migration_status=pending"]
        A5 --> A6{Repo exists in target?}
        A6 -->|no| A7[createRepo: GET source config → PUT target]
        A7 --> A8
        A6 -->|yes| A8["Flip config_status → completed<br/>migration_status stays pending, same row"]
    end

    A8 -.pipeline A ends, pipeline B runs on a schedule.-> B0

    subgraph B[" "]
        direction TB
        B0[Scheduled trigger — cron poll] --> B1["Filter tracking file<br/>config_status=completed AND migration_status=pending"]
        B1 --> B2["Grouping logic (core decision)<br/>batch by count/size thresholds<br/>→ batch of 1, 3, or 5 repos"]
        B2 --> B3{Any row with<br/>migration_status = in_progress?}
        B3 -->|yes| B3w[Wait for next scheduled poll]
        B3w --> B3
        B3 -->|no| B4["Set batch rows migration_status=in_progress<br/>notify team: migration started"]
        B4 --> B5[Run jf rt transfer-files per repo in batch]
        B5 --> B6{exit status?}
        B6 -->|non-zero| B6f["migration_status → pending (auto-retry)<br/>alert DevOps"]
        B6 -->|zero| B7["Diff check (diagnostic only)<br/>compare source vs target count + size"]
        B7 --> B8["migration_status → completed<br/>notify team: completed, source vs target count/size"]
    end
```

## Requirements

- A self-hosted GitHub Actions runner (the migration VM itself) with
  `jf c add source-server ...` and `jf c add target-server ...` already
  configured manually — no tokens or `jf` server setup happens inside
  the workflow
- GitHub Actions with `contents: write` permission on this repo (needed
  to commit the tracking file / request log back)
- `jf` CLI, `jq` on the runner (already required for the manual `jf c
  add` step above)

## Running a migration

1. One-time, manual: install the Data Transfer plugin on the source VM,
   and run `jf c add source-server ...` / `jf c add target-server ...`
   on the migration VM (self-hosted runner).
2. Trigger Pipeline A (currently `workflow_dispatch`, issue-based
   trigger planned) with the repo name.
3. Pipeline B picks it up on its next scheduled poll once
   `config_status` is `completed` — see docs/design.md for the poll
   interval and grouping thresholds, still open.

## Known limitations (see docs/design.md for detail)

- Plugin installation on the source VM is manual and not verified by
  this tool.
- Completion is determined by `jf rt transfer-files` exit status;
  file count/size differences are logged but do not block completion.
- Grouping/batch-size thresholds (1, 3, or 5 repos per batch) aren't
  decided yet.
- Pipeline B's poll interval (cron schedule) isn't decided yet.
- On failure, `migration_status` resets to `pending` for automatic
  retry on the next poll. There's no retry-count cutoff yet, so a
  persistently failing repo (bad permissions, corrupted data, etc.)
  will retry forever, once per poll cycle, alerting DevOps each time
  rather than eventually going terminal.
- Team notifications (start/completion) aren't wired to any channel
  yet — needs a Slack webhook, email, or similar picked.
- The progress-parsing regex in `migrate.sh` assumes a particular
  `jf rt transfer-files` output shape — verify it against your installed
  CLI version and adjust if the JSON progress line format differs.