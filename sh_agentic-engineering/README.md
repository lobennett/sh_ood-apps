# Agentic Engineering on Sherlock

`sh_agentic-engineering` starts a persistent [Herdr](https://herdr.dev) session
in a Sherlock Slurm allocation and opens the
[agentic-engineering](https://github.com/lobennett/agentic-engineering) setup
inside it: a workspace in your Firstmate home with the primary harness
(Claude Code, Codex, or Pi) already running. Open OnDemand owns the
allocation; you attach a terminal through OnDemand's own shell or from a
login node. Firstmate, the harnesses, and the shared skills come from that
public setup, not from this app.

The app has no browser terminal, open TCP port, or reverse-proxy URL. It never
collects credentials; sign in to each harness through its own flow and keep
secrets out of the form fields.

## One-time setup

1. **Install the agentic-engineering setup.** On a Sherlock login node, with
   this repository checked out at `~/src/sh_ood-apps`:

   ```bash
   module load system git
   bash ~/src/sh_ood-apps/sh_agentic-engineering/bin/setup
   ```

   This clones `lobennett/agentic-engineering` into
   `~/src/agentic-engineering` (or fast-forwards it) and runs its documented
   entry point, `setup.sh`, which installs Herdr to `~/.local/bin/herdr`,
   clones Firstmate to `~/firstmate` with `config/backend=herdr`, and installs
   the skills collection for the harnesses it finds. Pass `--check` to only
   report, or `--yes` to skip its prompts; override the locations with
   `AE_FIRSTMATE_DIR` and `AE_BIN_DIR`. `setup.sh` reports missing
   prerequisites (`git`, `curl`, `gh`, `node`, `jq`, and a harness) instead
   of installing them; load the matching Sherlock modules first. It does not
   run `gh auth login` or any harness sign-in.

2. **Sign in to your harness** once, in a normal compute session, so the
   Herdr pane can start it without an interactive login:

   ```bash
   sh_dev
   module load claude-code   # or: codex, pi-coding-agent
   claude                    # or: codex, pi
   exit
   ```

3. **Register the OnDemand apps** in your sandbox directory:

   ```bash
   bash ~/src/sh_ood-apps/install-apps.sh
   ```

   The app then appears under **Develop → My Sandbox Apps**. That menu exists
   only when the Sherlock team has enabled app development for your account;
   see the repository README.

## Start and attach

1. In OnDemand choose **Agentic Engineering**. The defaults are session
   `agentic-engineering`, harness Claude Code, Firstmate home
   `$HOME/firstmate`, partition `russpold`, 8 CPUs, 32 GB, and 8 hours.
   `normal` is also available. Additional modules are loaded after
   `system git` and the harness module.
2. Launch and wait for the card. Startup validates the Firstmate home
   (`AGENTS.md` must exist), the modules, Herdr, and the harness command,
   then starts the Herdr server, creates the workspace, and runs the harness
   in it.
3. Open a terminal as yourself: click the host button (`>_ sh…`) on the card
   for an OnDemand shell on the compute node, open **Clusters → Sherlock
   Shell Access** for a login-node shell, or `ssh -t sherlock` from your
   laptop. Then run the command shown on the card:

   ```bash
   bash -l /path/to/session/output/attach.sh JOB_ID
   ```

   The staged `attach.sh` checks that the job is `RUNNING`, belongs to you,
   and is on the recorded node, then starts the Herdr client in an explicit
   `srun --jobid … --overlap --pty` step of that job. Run it from a plain
   terminal: Herdr refuses to start a client inside another Herdr pane.

Detach with `Ctrl-B` then `Q`; panes and agents keep running until the
allocation ends. Reattach with the same command. Delete the session in
OnDemand (or `scancel JOB_ID`) when finished.

Inside the session, Firstmate runs in your Firstmate home with the Herdr
backend; it detects Herdr from `HERDR_ENV=1` and the `config/backend` file the
setup wrote. Firstmate itself asks before installing or upgrading anything it
needs (for example `gh` authentication or `jq`), per its documentation.

## Session names, ownership, and restore

The Herdr session name is the durable identity. Herdr keeps the saved layout
of a named session in your home directory, so launching the same name later
restores its workspaces, tabs, and panes, and resumes supported agents
natively. The Firstmate home field is used only when the session has no
saved workspace yet; a restored session does not start a new harness.

Slurm decides who owns a name. Each job is submitted with the job name
`sh_agentic-engineering/<session>`; at startup the job lists your active jobs
and fails if an older job carries the same name, so two allocations never
serve one session concurrently and no lock file can go stale. Use a
different session name for a second concurrent session. The Herdr app
(`sh_herdr`) uses a separate job-name space; do not reuse a name across the
two apps while both are running.

## State, logs, and troubleshooting

Per-job files live only in the Batch Connect staging directory:
`ae-job-id`, `ae-host`, `ae-socket`, the readiness markers `ae-ready`,
`ae-failed`, and `ae-restored`, `ae-startup.log`, and `herdr-server.log`.
The live socket is `/tmp/sherlock-agentic-engineering-<uid>-<job-id>/herdr.sock`
on the allocated node, inside a mode 0700 directory that the job removes when
it ends. Cleanup stops only this job's Herdr server, through that socket.

| Symptom | What to check |
| --- | --- |
| `Firstmate home … has no AGENTS.md` | Run `bin/setup` (or `setup.sh`) and select the Firstmate checkout it created. |
| `Herdr is not installed at ~/.local/bin/herdr` | Run `bin/setup`; confirm `~/.local/bin/herdr --version` on a login node. |
| `The claude command is unavailable` (or codex, pi) | Confirm the module names `claude-code`, `codex`, `pi-coding-agent` with `ml spider`. |
| `Could not load the additional modules` | Correct or remove the optional module names. |
| `already owned by your Slurm job N` | Attach to job N, cancel it, or choose another session name. |
| `Herdr server exited before becoming ready` | Read `herdr-server.log` in the session output directory; an incompatible existing saved session or a failed `~/.local/bin/herdr` are the usual causes. |
| `attach.sh` reports the job is not `RUNNING` or belongs to another node | Use the command from the current card; a new allocation has a new job ID and node. |
| `nested Herdr clients are disabled` | Run the attach command from a plain terminal, not from inside Herdr. |
| The harness pane asks you to sign in | Complete that harness's own sign-in in a compute session, then relaunch or start it again in the pane. |

An expired or cancelled allocation ends every process on the node. The named
session's saved layout and Firstmate's own on-disk state in its home remain.

## Security model

- No browser shell, TCP port, reverse-proxy URL, or user-run SSH server. The
  only connection path is OnDemand's authenticated shell (or your own SSH to
  a login node) plus an `srun` step that Slurm binds to your job.
- The app collects no passwords, API keys, OAuth tokens, or harness
  credentials and writes none to disk. Harness sign-ins stay with the
  harnesses in your home directory.
- Form values are validated and shell-quoted; the session name is restricted
  to letters, digits, `.`, `_`, and `-` (64 characters at most), the Firstmate
  home must be an existing directory, and module names are quoted
  individually. There is no free-form command field.
- Runtime files are private (umask 077), the socket directory is mode 0700,
  and cleanup removes only this job's directory.

## Verification

Local tests render the real templates and exercise the lifecycle against
controlled Slurm, module, and Herdr doubles:

```bash
bash sh_agentic-engineering/test/run
```

They cover form and resource rendering, the job-name ownership guard, a
fresh session (server start, workspace, harness launch, readiness), a
restored session, every startup failure path, cleanup on `TERM` and on server
death, the attach helper's job checks and `srun` binding, quoting, and the
connection view. The Herdr CLI calls (`status server --json`,
`workspace list`, `workspace create`, `pane run`, `server stop`) were also
checked against a real Herdr 0.8.2 in an isolated local session; their JSON
shapes are what the doubles reproduce.

Not yet exercised: an actual OnDemand launch on Sherlock, including Herdr
0.8.2+ on a compute node, the `>_` host shell, `attach.sh` through
`srun --pty`, Firstmate's first run inside the session, and job cancellation.
Treat one complete launch, attach, detach, reattach, and delete cycle as the
deployment acceptance check.

Upstream references: [Herdr CLI reference](https://herdr.dev/docs/cli-reference/),
[Herdr session state and restore](https://herdr.dev/docs/session-state/),
[Firstmate Herdr backend](https://github.com/lobennett/firstmate/blob/main/docs/herdr-backend.md),
[Sherlock AI coding agents](https://www.sherlock.stanford.edu/docs/software/ai/coding-agents/),
[Sherlock compute-node access](https://www.sherlock.stanford.edu/docs/user-guide/running-jobs/#connecting-to-nodes).
