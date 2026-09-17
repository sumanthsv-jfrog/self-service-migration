# Design notes

## Why shell + GitHub Actions (not Python)

Chosen over a standalone Python service: no separate host/VM to run and
maintain the tool itself, migration history is visible as workflow runs
and commits, and access control piggybacks on repo permissions instead
of a bespoke auth layer. Tradeoff: no long-lived process, so anything
that used to be "poll from outside" has to become "poll from inside a
single job run, commit updates as you go" (see State tracking below).

## Flow

1. **Manual, one-time:** Data Transfer plugin configured on the source VM
   by an admin. Not checked or managed by this tool — if a job fails
   immediately at transfer start with no other explanation, check this
   first.
2. **Trigger:** `workflow_dispatch` with `repo_name` and `env` inputs, run
   manually from the Actions tab for now. Planned next: an issue-based
   trigger — opening an issue (or commenting a slash-command) with the
   repo name kicks off the same workflow via `workflow_call`, and the
   workflow comments back on the issue with status/completion. Not yet
   built; `workflow_dispatch` ships first.
3. **Pre-flight:** `jf rt ping` against source and target, run by the
   Actions runner itself — this is the actual execution environment, not
   a developer's laptop. Fails fast on unreachable/bad-auth.
4. **Repo existence check:** if the repo doesn't exist in target, create
   it from an **allowlisted** subset of source config (key, packageType,
   rclass, layout, repoLayoutRef, description). Explicitly **not**
   copied: storage backend/binary provider details, permissions/ACLs,
   replication settings. If a same-named repo exists with a different
   type/class than source, fail rather than migrate into a mismatch.
5. **Queueing:** handled entirely by GitHub Actions' native
   `concurrency:` group (`migrate-<env>`, `cancel-in-progress: false`).
   A second dispatch for the same env queues automatically; no custom
   lock file or atomic-claim logic needed. This replaces what would have
   been a hand-rolled queue in a long-lived-process design.
6. **Migration:** `jf rt transfer-files` runs in the background of the
   job step; a polling loop checks its output every
   `POLL_INTERVAL_SECONDS` (default 30) and commits progress into
   `state/<job_id>.json`.
7. **Completion:** determined by `transfer-files`' own exit status, not a
   separate verification step. File count and total size are still
   compared (source vs target `repo-get` output today — see TODO below)
   and written into `diff_notes`, but only as a logged diagnostic;
   legitimate differences (metadata, in-flight files, trash/cache
   artifacts) are expected and don't fail an otherwise-successful job.

## State tracking

State lives at `state/<job_id>.json` and is **committed and pushed** by
`scripts/state.sh` at every lifecycle transition, plus periodically
during transfer. Practical implications of that choice, worth being
deliberate about:

- **Commit volume.** A default 30s poll interval on a long transfer
  produces a lot of small commits. Fine as an audit trail; squash or
  adjust `POLL_INTERVAL_SECONDS` if that's too noisy for your repo's
  history.
- **Push conflicts.** Since `concurrency:` limits one run per env at a
  time, two jobs for the *same* env can't race on the same push. Two
  jobs for *different* envs running simultaneously both push to the same
  branch — `git push` can fail on a non-fast-forward. `state.sh` doesn't
  currently retry/rebase on push failure; worth adding if you expect
  multiple envs to run concurrently in practice.
- **Where progress numbers come from:** parsed out of `jf rt
  transfer-files`' own stdout in `migrate.sh` via a regex looking for a
  `filesTransferred`/`bytesTransferred` JSON line. This is the most
  fragile part of the script — verify against your installed `jf` CLI
  version's actual output format before relying on it, and adjust the
  `grep`/`jq` pattern if it doesn't match.

## Queue mechanism (superseded)

An earlier design (see git history / prior conversation) used a
hand-rolled atomic lock file plus a FIFO queue file, with small repos
batched together before the queue write. With GitHub Actions doing the
queueing natively via `concurrency:` groups, that mechanism is dropped
entirely for ordering/exclusivity.

**Not yet replaced:** small-repo batching. GitHub's concurrency group
gives you one-at-a-time ordering, but nothing that combines several
small pending repos into a single `transfer-files` call. If that still
matters, it likely needs to live as a pre-dispatch step (a script that
checks the GitHub API for other queued/recent runs for the same env and
decides whether to wait and batch) rather than inside the workflow
itself.

## Repo config allowlist

Same allowlist as before: `key`, `rclass`, `packageType`,
`repoLayoutRef`, `description`, `url`, `layout`. Extend
`ALLOWLIST` in `scripts/repo_manager.sh` deliberately, field by field —
never switch to a blocklist, since new API fields should default to
*not* being copied until reviewed.

## Known limitations / accepted tradeoffs

- **Plugin install is manual and invisible to this tool.** A migration
  that fails because the plugin was never configured just looks like a
  generic `transfer-files` failure. Documented in the admin runbook
  instead of detected in code.
- **Completion ≠ verified identical content.** File count/size match is
  informational only, not per-file checksum verification. Relies on
  Data Transfer's own integrity handling during the copy.
- **Progress-parsing is CLI-output-format-dependent.** See State
  tracking above.
- **No small-repo batching yet.** See Queue mechanism above.

## Open questions / TODO

- [ ] Build the GitHub issue-based trigger (workflow_call + issue
      comment for status).
- [ ] Swap the `repo-get`-based file count/size lookup for the real
      repository summary/storage-info API — `repo-get` returns config,
      not usage stats.
- [ ] Decide whether push-conflict retry logic is needed for
      `state.sh` (matters once multiple envs run concurrently).
- [ ] Small-repo batching strategy, if still wanted (see above).
- [ ] Notifications (email/Slack) on completion/failure — currently only
      visible via the workflow run log and the issue comment (once
      built).
- [ ] Access control: who can trigger `workflow_dispatch` for which
      repos — currently anyone with repo write access.
- [ ] Target storage/quota pre-flight check before starting large
      transfers.
- [ ] Retry/resume story for interrupted transfers.
