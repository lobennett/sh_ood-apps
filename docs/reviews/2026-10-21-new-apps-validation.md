# New app validation — 2026-10-21

## Installed locations

- New app checkout: `~/src/sh_ood-apps-newapps`, branch `feature/sh-supacode`.
- Sandbox links: `~/ondemand/dev/sh_marimo` and `~/ondemand/dev/sh_supacode`.
- Marimo 0.25.2 environment: `$GROUP_HOME/logben/software/sherlock-marimo/venv`,
  linked from `~/.local/share/sherlock-marimo/venv`. Home was 94% full, so the
  packages were installed in personal group storage; rebuildable caches use scratch.
- Existing `~/src/sh_ood-apps` and the deployed Herdr link remain unchanged.

## Validation

- Supacode: 10 automated tests pass locally and on Sherlock. Both rendered
  agent dependency checks passed inside allocation 48887595. A real `srun`
  step reported that job ID and the requested working directory; installed
  CLIs reported Claude Code 2.1.280 and Codex 0.156.0.
- Marimo: 10 tests / 122 assertions pass locally and on Sherlock. A real-server
  smoke test passes on both platforms, covering authentication denial, native
  login POST, secure scoped cookies, browser assets, workspace access, notebook
  WebSockets, and absence of passwords in logs and process arguments.
- Actual OnDemand launch: job 48889032, `dev`, 2 CPUs, 4 GB, 1 hour. The browser
  connected through `/node/sh04-18n31.int/6885/`; a notebook executed a cell,
  displayed **42** and the correct job/host, saved as `sherlock_marimo_check.py`
  in the new checkout, and reconnected after reload. The notebook is a personal
  acceptance artifact, not part of the Git branch. The session was left for
  the user and expires after its requested hour (about 17:46 PDT).
- Existing Herdr suites pass locally: four Bash suites plus 9 Ruby tests /
  120 assertions. ShellCheck was unavailable. See the separate Herdr review
  for defects and untested live behavior.

Cluster validation also corrected test isolation: exported scheduler functions
and Lmod's `BASH_ENV` must not replace controlled test boundaries. The Marimo
smoke test accepts `--modules` so a module-backed Python retains its required
shared libraries. These failures were observed before their fixture fixes.

## Review and remaining limits

A fresh independent review found one material Supacode defect: checking a job
with `squeue` did not bind a bare SSH-launched agent to that job. The launcher
now uses `srun` with explicit job, node, task count, CPU width, and working
directory. Its regression test failed before the fix and passes afterward.
No minor findings were deferred from that review.

The complete Mac Supacode GUI workflow remains untested. It requires compatible
Supacode (reviewed against 0.11.5), normal SSH authentication/host-key confirmation,
agent sign-in, and modern Git in the remote login shell. The installed Mac app
was 0.10.5; the default Sherlock login shell exposed Git 1.8.3.1. The README
documents the available Git 2.45.1 module. Neither the Mac SSH configuration nor
the user's login profile was changed. When several jobs share a node, the SSH
transport may belong to another allocation even though the agent's Slurm step
is explicitly bound; ending that other job can interrupt the connection.

Live Marimo job cancellation and full Supacode cgroup/cancellation behavior
were not exercised. Automated lifecycle checks passed. Herdr live startup,
attachment, cancellation, and restoration were not exercised.

## Implementation decisions

- Used an isolated temporary clone instead of another linked worktree; this
  leaves the existing checkout alone. Cost if a different layout is preferred:
  relocate the clone.
- Proceeded with the user's accepted Mac workflow and routine implementation
  choices; Marimo was implemented separately and both apps received a fresh
  combined review. Remaining uncertainty is the live Mac workflow above.
- Kept both additions on one branch, with commits grouped by app and its
  documentation. They can be split into separate PRs if desired; no runtime cost.
- Deployed only the two new sandbox apps from a separate checkout after local
  verification, as part of making Marimo available. Existing Herdr remains intact.
- Retained explicit live-test limits instead of treating source review and
  mocks as proof of all deployed behavior. Untested SSH/cancellation behavior
  may still expose integration issues.
- Used the separate Herdr review and the independently reproduced lock race;
  the final new-app reviewer did not repeat that investigation. Findings may
  need refinement when Herdr is fixed and tested live.
