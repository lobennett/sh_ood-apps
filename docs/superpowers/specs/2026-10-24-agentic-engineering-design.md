# Agentic Engineering on Sherlock

Add `sh_agentic-engineering`, a Batch Connect app that launches the public
[agentic-engineering](https://github.com/lobennett/agentic-engineering) setup
(Herdr, Firstmate, the Claude Code / Codex / Pi harnesses, and the shared
skills) as a persistent interactive session on one Sherlock compute node, and
add a root-level `install-apps.sh` that registers this checkout's sandbox apps
in the invoking user's own OnDemand directory.

## Session shape

The job runs a headless Herdr server for a user-named session, with a private
Unix socket under `/tmp/sherlock-agentic-engineering-<uid>-<job>/`, exactly as
`sh_herdr` does. When the named session has no saved workspace, the job creates
one in the user's Firstmate home and runs the selected harness in its root pane
through `herdr pane run`; Firstmate then takes over inside that pane (it
auto-detects Herdr from `HERDR_ENV=1`). A session with a saved layout is
restored by Herdr untouched. The job holds the allocation while the server is
healthy and stops only its own server through its own socket when the job ends.

Users attach through OnDemand's authenticated shell (the session card's host
button or Sherlock Shell Access) or their own SSH to a login node, then run the
staged `attach.sh`, which verifies job ownership, state, and node, and starts
`herdr client` in an explicit `srun --jobid … --overlap --pty` step of the job.
No browser terminal, TCP port, or proxy route is added.

## Ownership without lock files

Each job is submitted with the Slurm job name `sh_agentic-engineering/<session>`.
At startup the job lists the user's active jobs and fails when an older job
carries the same name. Slurm is the single authority on which allocation owns a
session name, so the stale-lock race found in the Herdr app's shared-filesystem
registry cannot occur here, and nothing persists after the job ends. The app
keeps per-job metadata only in the Batch Connect staging directory.

## Integration interface with agentic-engineering

The two repositories progress independently against a small interface, as
published by the agentic-engineering worker: the entry point `setup.sh` (flags
`--check`, `--yes`), Herdr at `~/.local/bin/herdr` (`AE_BIN_DIR`), Firstmate at
`~/firstmate` (`AE_FIRSTMATE_DIR`) with `config/backend=herdr`, and user-level
skill installs for the harnesses. `sh_agentic-engineering/bin/setup` clones or
fast-forwards that repository into `~/src/agentic-engineering` and runs
`setup.sh`; the job itself only consumes the installed Herdr binary and
Firstmate home, and reports a missing piece with a pointer to the setup. The
harnesses come from Sherlock's documented modules `claude-code`, `codex`, and
`pi-coding-agent`.

## Installer

`install-apps.sh` symlinks `sh_agentic-engineering`, `sh_herdr`, `sh_marimo`,
and `sh_supacode` (the apps Sherlock does not already provide system-wide)
from the checkout into `~/ondemand/dev`, the documented per-user development
app directory. Repeated runs are no-ops; a real file or directory at a target
path is never removed; a symlink pointing elsewhere is replaced only with
`--force`; `--remove` deletes only links into this checkout. The script states
the site-side prerequisite it cannot perform: the Sherlock team must enable app
development for the account before the Develop menu appears.

## Verification

Ruby and Bash tests render the real templates and run the lifecycle, attach
helper, setup script, and installer against controlled Slurm, module, Herdr,
and Git doubles. The Herdr CLI calls and JSON shapes the doubles reproduce were
checked against a real Herdr 0.8.2 in an isolated local lab session. An actual
OnDemand launch on Sherlock remains the deployment acceptance check and has not
been performed.
