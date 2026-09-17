# JFrog repository audit toolkit

Scripts and browser tools for auditing JFrog Artifactory repository
configuration from a support bundle — no API access or credentials
required. Everything reads local files and runs entirely offline.

## What's in here

| File | What it does |
|---|---|
| `jfrog-repo-config-audit-offline.sh` | Reads one instance's repo config and reports local/remote/federated/virtual counts, nested virtuals, and circular references |
| `repo-map.html` | Browser tool to explore one instance's repos interactively |
| `jfrog-repo-compare.sh` | Compares two instances' repo configs and finds duplicate/unique repo keys |
| `compare-view.html` | Browser tool to explore the comparison results interactively |

Requires `jq` (`brew install jq` on macOS). No other dependencies.

## Workflow 1: audit a single instance

**1. Get the config file**

Pull `artifactory.repository.config.json` from that instance's support
bundle.

**2. Run the audit script**

```bash
./jfrog-repo-config-audit-offline.sh artifactory.repository.config.json
```

This prints a summary to the terminal and writes a CSV
(`jfrog-repo-config-<date>.csv` by default, or pass `--output myfile.csv`).

**3. Explore the results**

Open `repo-map.html` in any browser (just double-click it — no server
needed), click **Upload CSV**, and select the CSV from step 2.

You can then:
- Browse repos by type (local / remote / federated / virtual)
- Click any repo to see its relationships — what it contains, and which
  virtuals it's used by
- See circular references flagged up front, with the full chain shown

## Workflow 2: compare two instances

**1. Get both config files**

Pull `artifactory.repository.config.json` from each instance's support
bundle.

**2. Run the comparison script**

```bash
./jfrog-repo-compare.sh instance1.json instance2.json \
    --label1 "Prod" --label2 "DR" \
    --output compare.csv
```

`--label1` / `--label2` / `--output` are optional. This prints a summary
(duplicate count, unique-to-each count, any type mismatches) and writes
`compare.csv`.

**3. Explore the results**

Open `compare-view.html` in any browser, click **Upload CSV**, and select
`compare.csv` from step 2.

You can then:
- See repo keys that exist in **both** instances (duplicates)
- See repos unique to each instance
- Filter to just the duplicates whose type differs between instances
- Click any repo for a side-by-side comparison

## Notes

- Both `.html` tools are single self-contained files — no build step, no
  server, no internet required (aside from optional web fonts, which
  fall back gracefully if you're offline).
- Nothing is uploaded anywhere. CSV parsing and analysis happen entirely
  in your browser.
- Re-run the scripts any time your config changes and re-upload the new
  CSV — the tools don't need to be regenerated.
