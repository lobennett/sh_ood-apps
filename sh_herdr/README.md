# Sherlock Herdr

The `sh_herdr` Open OnDemand app starts a persistent [Herdr](https://herdr.dev)
workspace in a Sherlock Slurm allocation. Open OnDemand owns the allocation;
the local `sherlock-herdr` command attaches a terminal through the Sherlock
login node and the existing allocation.

Herdr state persists in the user's shared home directory, while its live Unix
socket is kept in a private directory on the allocated compute node. The app
does not provide a browser shell or a TCP service, and it does not copy or
store agent credentials.

## One-time setup

### On Sherlock

From a Sherlock login node, run the setup command from the feature checkout:

```bash
bash ~/src/sh_ood-apps/sh_herdr/bin/setup
```

This installs or updates Herdr under `~/.local/bin` and installs the trusted
remote attachment helper and runtime library under `~/.local`. Setup prints
the Herdr version and the next local-installation steps. It is the only step
that downloads Herdr; compute jobs use the installed copy.

### On your laptop

Copy the local wrapper from Sherlock and make it executable:

```bash
scp sherlock:~/src/sh_ood-apps/sh_herdr/bin/sherlock-herdr ~/.local/bin/
chmod 755 ~/.local/bin/sherlock-herdr
```

The wrapper accepts only a numeric Slurm job ID and always connects through
the SSH host alias `sherlock`.

Configure that alias in `~/.ssh/config`. The following is a personal example;
other users must replace `logben` with their own Sherlock username:

```sshconfig
Host sherlock
  HostName login.sherlock.stanford.edu
  User logben
```

Check the alias before launching a session:

```bash
ssh sherlock true
```

## Authenticate the agent CLIs

Authenticate `claude` and `codex` once in a normal Sherlock compute session,
before launching agents from Herdr. For example, start a short interactive
allocation, load the same modules used by the app, run each CLI, and complete
its interactive sign-in flow:

```bash
srun --pty --partition=russpold --nodes=1 --cpus-per-task=2 --mem=4G --time=00:30:00 bash
module load claude-code codex
claude
codex
exit
```

Exit each CLI after authentication. The CLIs keep their own configuration in
your shared home directory; this app never places those credentials in the
Open OnDemand session or its registry. Authenticate only the CLI(s) you plan
to select in the form.

## Start and attach

1. Open <https://ondemand.sherlock.stanford.edu> and choose **Herdr** under
   the development Interactive Apps.
2. Choose a session name, agent environment, initial workspace, partition,
   resources, and optional module/initialization settings. The defaults are
   session `sherlock`, agents `Both`, partition `russpold`, 8 CPUs, 32 GB, and
   8 hours. The available partitions are `russpold` and `normal`.
3. Submit the job and wait for the session card to report that the server is
   ready. Copy the Slurm job ID shown on that card.
4. On your laptop, run:

   ```bash
   sherlock-herdr JOB_ID
   ```

   Replace `JOB_ID` with the copied decimal job ID. The helper verifies that
   the job is still `RUNNING` and belongs to you, then enters that allocation
   with an overlapping `srun` step and attaches to the recorded Herdr socket.

Detach with Herdr's terminal sequence, `Ctrl-B` followed by `Q`. Detaching
leaves the allocation, Herdr server, panes, and agents running. Reattach at
any time while the allocation is active by running the same command again:

```bash
sherlock-herdr JOB_ID
```

When finished, cancel the allocation from the OnDemand session card or with
Slurm:

```bash
scancel JOB_ID
```

Cancellation disconnects attached clients and stops the compute-node server.
Cleanup removes the temporary socket directory and this job's registry
record, but preserves Herdr's durable named-session data.

## Named sessions and restoration

The session name is the durable logical identity. Reusing `sherlock` (or any
other name) in a later allocation lets Herdr restore its saved workspace shape
and supported native agent sessions from shared home storage. The selected
workspace is used to create the initial workspace only when that named session
has no workspace yet.

Only one active allocation may own a name. A second job using the same name
fails with the current owning job ID; choose a different name for concurrent
allocations. A lock is reclaimed only after Slurm confirms that its recorded
job has ended, so an apparently stale name should not be removed manually
while its job may still be running.

## State, logs, and troubleshooting

The private registry is:

```text
~/.local/state/sherlock-herdr/
├── jobs/<JOB_ID>
└── sessions/<SESSION_NAME>/owner_job
```

Directories are mode `0700` and registry files are mode `0600`. A job record
contains only the validated session name, compute-node socket path, and host.
Herdr's durable data remains in its own home-directory state. The live socket
is `/tmp/sherlock-herdr-<uid>-<job-id>/herdr.sock` on the allocated node and is
removed when that job exits.

The Batch Connect staging directory contains `herdr-server.log`; startup and
timeout errors also print that log. Look at the job's OnDemand output/log
files when a session does not become ready. The workspace is deliberately not
used for this log, so changing workspaces does not hide startup diagnostics.

Common failures:

| Symptom | What to check |
| --- | --- |
| `module load` fails | Confirm the Sherlock module names `claude-code` and `codex`; remove or correct optional module names. |
| `Claude command is unavailable` or `Codex command is unavailable` | Select the matching agent environment and verify the module is loaded and the CLI was authenticated in a compute session. |
| `herdr is not available` | Run `bash ~/src/sh_ood-apps/sh_herdr/bin/setup` on Sherlock and confirm `~/.local/bin/herdr --version`. |
| Setup cannot install the helper | Confirm the checkout path, write access to `~/.local`, and that `sherlock-herdr-attach` and `runtime.sh` exist in the checkout. |
| Workspace or session validation fails | Use an existing directory and a session name beginning with a letter or number; only letters, numbers, `.`, `_`, and `-` are accepted. |
| Job is rejected as pending, missing, or foreign | Wait for `RUNNING`, use the job ID from your own session card, or cancel the old allocation. |
| Session name is already in use | Reattach to the owning job, choose another name, or wait until Slurm confirms the old allocation has ended. |
| The allocation expired | The attachment is expected to disconnect. Start another allocation with the same name to restore durable Herdr state. |

An expired or canceled allocation does not preserve processes on the compute
node. It does preserve the named session's durable data in home storage.

## Security model

- The app has no browser shell, open TCP port, reverse-proxy URL, or direct
  compute-node SSH path.
- No password, API key, OAuth token, SSH secret, or Claude/Codex credential is
  stored in Open OnDemand metadata or the Herdr registry.
- The local wrapper supplies only a numeric job ID. The trusted Sherlock-side
  helper verifies job ownership and state before invoking `srun`.
- Session names and paths are validated, state directories are private, and
  cleanup is ownership-aware and restricted to the current job's exact runtime
  directory.

The advanced initialization field is intentionally an escape hatch: its
commands execute as the user, and a failing command can prevent startup. Do
not paste credentials or secrets into that field.

## Local verification

From the repository root, run the complete dependency-ordered test suite:

```bash
bash sh_herdr/test/run
```

The runner executes runtime, helper, setup, template, and lifecycle tests. It
also runs ShellCheck when installed and otherwise prints one skip notice.
