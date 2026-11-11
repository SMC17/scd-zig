# Try scd-zig

Replay a two-season dimension history and require incremental output to equal full backfill.

Use Zig 0.16.0:

```sh
zig build test -Doptimize=ReleaseSafe --summary all
zig build demo -Doptimize=ReleaseSafe
```

The fixture checks its result and returns nonzero on a mismatch. Inputs are
synthetic; no external account, downloaded data or sibling checkout is needed.
Read the API and existing limitations before using it on another workload.

## Package it from committed source

With Python 3.12 or newer, choose a new directory outside this checkout:

```sh
python3 tools/selfserve.py selfserve.json --repo . --out ../scd-zig-pack
```

The tool extracts HEAD to a fresh directory, runs the task there and writes
source, the fixture binary, result.json, command logs, TRY.md and SHA256SUMS.
Untracked workstation state cannot satisfy a check. A failed step, timeout
or test count below the recorded floor blocks a passing result.

## Ongoing maintenance

The self-serve workflow runs on relevant pull requests, main updates, manual
requests and a monthly schedule. A maintainer-pushed `selfserve-*` tag can
publish a prerelease only after both native Linux and macOS jobs pass. No tag
is created by this change. Repository visibility is unchanged. GitHub account
billing currently prevents hosted jobs from starting, so no hosted pass is
claimed. Local acceptance and hosted acceptance remain separate.

A pack is evidence for this small task, not proof of every advertised feature.

## Common questions

- **The pack says FAIL.** Read the first failing step in result.json and its
  log. A completed build with no executed tests is insufficient; a missing
  promised binary is also a failure.
- **Where do I report a failure?** Use the self-serve task issue form with the
  source commit/checksum, platform, exact command, expected result and output.
  You do not need a private message or an external service to reproduce it.
- **Will the schedule run forever?** GitHub can disable scheduled workflows in
  inactive public repositories after 60 days. Push/manual triggers remain
  separate. Inspect Actions when a monthly result becomes stale; this system
  does not manufacture commits to keep schedules alive.

[GitHub's schedule policy](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/disable-and-enable-workflows)
