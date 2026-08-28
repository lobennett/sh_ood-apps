# Sherlock Herdr Open OnDemand App

## Purpose

The `sh_herdr` app gives a Sherlock user a durable Herdr workspace on a Slurm compute node. Open OnDemand allocates the node and manages the job. A small command on the user's laptop attaches a local terminal to Herdr through Sherlock's login node and the existing Slurm allocation.

The app does not expose a browser terminal or a network service. It does not store agent credentials. Claude Code and Codex come from Sherlock's module system and read the user's existing configuration from the shared home directory.

The code should be clean enough to submit upstream, but it will remain on a feature branch in `lobennett/sh_ood-apps`. No pull request will be opened.

## Repository and deployment layout

The fork's `main` branch will match `stanford-rc/sh_ood-apps:main` exactly. Development will occur on `feature/sh-herdr`, created from that upstream commit.

Sherlock will hold the feature checkout at:

```text
~/src/sh_ood-apps
```

Open OnDemand will see only the shared form support and the new app:

```text
~/ondemand/dev/_common  -> ~/src/sh_ood-apps/_common
~/ondemand/dev/sh_herdr -> ~/src/sh_ood-apps/sh_herdr
```

The obsolete `~/ondemand/dev/sh_cursor` and `~/ondemand/dev/on_demand_containers` directories will be removed after their exact paths are verified.

## Components

### Batch Connect app

`sh_herdr` follows the existing Sherlock apps and Open OnDemand's Batch Connect conventions:

```text
sh_herdr/
├── README.md
├── form.js -> ../_common/form.js
├── form.yml.erb
├── manifest.yml
├── submit.yml.erb
├── view.html.erb
├── bin/
│   ├── setup
│   ├── sherlock-herdr
│   └── sherlock-herdr-attach
└── template/
    ├── after.sh.erb
    ├── before.sh.erb
    └── script.sh.erb
```

The three commands have separate responsibilities:

- `setup` installs or updates the stable Herdr binary and the remote attachment support under the user's home directory. Compute jobs never download software.
- `sherlock-herdr` runs on macOS or Linux. It accepts a Slurm job ID, connects to the SSH alias `sherlock`, and calls the remote attachment command.
- `sherlock-herdr-attach` runs on Sherlock. It validates the job and enters its allocation with an overlapping pseudo-terminal Slurm step.

### Session registry

The app stores runtime metadata under:

```text
~/.local/state/sherlock-herdr/
├── jobs/<job-id>
└── sessions/<session-name>/
```

The state directory has mode `0700`, and its files have mode `0600`. A job record maps a numeric Slurm job ID to a validated Herdr session name and node-local socket path. A session directory acts as an atomic lock and records the owning job, hostname, and server process.

Herdr keeps durable session data in the shared home directory. Its live Unix socket resides in a private directory under `/tmp` on the allocated compute node. This avoids placing a Unix socket on Sherlock's shared home filesystem. The registry gives the attachment helper the exact socket path, and cleanup removes the node-local directory when the allocation ends.

For Herdr 0.8.2, every lifecycle and attachment invocation sets both `HERDR_SESSION` and `HERDR_SOCKET_PATH` and omits the explicit `--session` flag. Herdr resolves `--session` before the socket override; the environment-only form therefore preserves the logical named session while forcing the live socket onto the compute node's private runtime directory.

Lifecycle scripts invoke `${SHERLOCK_HERDR_BIN:-$HOME/.local/bin/herdr}` explicitly rather than relying on `PATH`, because Sherlock's `module reset` removes `$HOME/.local/bin`. The override exists for testing and non-default installations and is not exposed in the OnDemand form.

The registry contains no credentials. The local helper supplies only a job ID; the trusted remote helper reads the session name from the registry.

## User form

The form exposes these fields:

| Field | Default | Behavior |
| --- | --- | --- |
| Herdr session | `sherlock` | Letters, numbers, `.`, `_`, and `-` only |
| Agent environment | `Both` | `Both`, `Claude`, `Codex`, or `None` |
| Initial workspace | `$HOME` | Directory picker |
| Partition | `russpold` | `russpold` or `normal` |
| CPUs | `8` | Positive integer |
| Memory | `32 GB` | Positive integer |
| Runtime | `8 hours` | Positive value accepted by Sherlock's form conventions |
| Additional modules | empty | Optional advanced field |
| Initialization commands | empty | Optional advanced field, executed as entered |

The app requests one node. It does not expose a GPU field because the initial use case is agent orchestration and software development.

The agent choices map to Sherlock's `claude-code` and `codex` modules. The implementation will verify those identifiers with the module system during deployment. It will load agent modules before optional modules and initialization commands, then confirm that every selected CLI is callable.

## Launch lifecycle

1. Open OnDemand renders the form and submits a one-node Slurm job with the selected partition, CPU, memory, and wall-time values.
2. The job validates the session name before using it in a path or command.
3. The job creates the session lock atomically. If another running job owns the name, startup stops and identifies that job. If the recorded job no longer exists, the job reclaims the stale lock.
4. The job resets the module environment, loads Herdr's prerequisites and the selected Claude/Codex modules, then applies optional modules and initialization commands.
5. The job confirms that `herdr` and every selected agent CLI are executable.
6. The job creates a private node-local runtime directory and Unix socket path.
7. The job writes its registry entry atomically and starts the named Herdr server from the selected workspace.
8. The startup hook polls Herdr's local status interface and requires the complete compact JSON text to start with `{`, end with `}`, and contain the exact boolean field `"running":true`, followed by `,` or `}`; false, absent, leading/trailing junk, and malformed fields are rejected. The check is implemented in Bash without Ruby, Python, or `jq`, because those interpreters are not guaranteed after `module reset` on compute nodes. Open OnDemand marks the session ready only after that predicate succeeds. The marker and server log use absolute paths rooted in the Batch Connect staging directory captured before the job enters the workspace.
9. The connection view shows the Slurm job ID, Herdr session name, initial workspace, and the command `sherlock-herdr <job-id>`.

The Batch Connect configuration passes the validated session name through a custom connection parameter. The view reads the scheduler job ID from Open OnDemand's session object. The app does not allocate a TCP port.

## Attachment lifecycle

The user configures this local SSH alias:

```sshconfig
Host sherlock
  HostName login.sherlock.stanford.edu
  User logben
```

The local command:

```text
sherlock-herdr <job-id>
```

performs these steps:

1. Reject a missing or non-numeric job ID.
2. Run the remote attachment helper through `ssh -tt sherlock`.
3. Query Slurm for the job and require it to be running and owned by the current Sherlock user.
4. Read the session name from the protected job registry and validate it again.
5. Enter the existing allocation with `srun --jobid <job-id> --overlap --pty`.
6. Attach a Herdr client to the named server inside that allocation.

The user can detach without ending the job. Herdr, its panes, and its agents remain on the compute node until the allocation ends or the user cancels it.

## Persistence and concurrency

The form defaults to the stable logical session name `sherlock`. When a later allocation reuses that name, Herdr restores the saved workspace shape and supported native agent sessions from the shared home directory.

Users can run independent allocations by choosing different session names. The lock prevents two active jobs from using the same name. Stale locks are reclaimed only after Slurm confirms that their recorded jobs are no longer active.

## Shutdown and cleanup

The batch script traps normal exit and scheduler termination signals. Cleanup:

1. Stops only the Herdr server process started by the current job.
2. Removes the job record only if it still identifies the current job.
3. Removes the session lock only if the current job still owns it.
4. Removes the private node-local runtime directory.
5. Leaves Herdr's durable session state intact.

The trap must be idempotent so that repeated signals cannot remove another allocation's state.

## Security model

The app relies on Open OnDemand, OpenSSH, and Slurm for authentication and authorization. It adds these controls:

- No listening network port, reverse proxy, or browser shell.
- No API keys, OAuth tokens, SSH secrets, or agent credentials in Open OnDemand metadata or the session registry.
- Numeric-only job IDs and a strict allowlist for session names.
- Shell arguments passed as arguments, not evaluated command strings.
- Job ownership and running-state checks before `srun`.
- Private state directories, atomic writes, and ownership-aware cleanup.
- Exact-path checks before legacy app removal.
- `--force-with-lease`, not an unconditional force push, when synchronizing the fork.

The advanced initialization field is intentionally an escape hatch. Its label must state that the app executes those commands as the user and that failures can prevent startup.

## Failure behavior

Startup fails with a clear job log when:

- Herdr is not installed.
- A selected module cannot load.
- A selected agent command is unavailable.
- The workspace does not exist or is not a directory.
- The session name is invalid or belongs to another running job.
- Herdr does not become ready within the startup timeout.

Attachment fails with a concise message when:

- The job ID is malformed, absent, not owned by the user, or not running.
- The job registry is missing or inconsistent.
- The allocation will not accept an overlapping step.
- Herdr is no longer responding inside the allocation.

An expired allocation disconnects attached clients. The next allocation can reuse the same session name and restore its saved state.

## Testing

### Static checks

- Render and parse the ERB-backed YAML with representative contexts.
- Validate the manifest and connection view syntax.
- Run ShellCheck on executable shell files where ShellCheck is available.
- Confirm executable modes and a clean Git diff.
- Compare resource and form conventions with the existing Sherlock apps.

### Helper tests

Tests replace `ssh`, `squeue`, `scontrol`, `srun`, and `herdr` with controlled fakes. They cover:

- A successful attachment.
- Missing and malformed job IDs.
- A job owned by another user.
- Pending, completed, and missing jobs.
- Missing and inconsistent registry entries.
- Invalid stored session names.
- A duplicate live session and a reclaimable stale lock.
- Quoting and command-injection attempts.
- Idempotent, ownership-aware cleanup.

### Sherlock smoke test

The deployment test will:

1. Confirm the exact Claude and Codex module names.
2. Confirm Herdr runs on a Sherlock compute node.
3. Start a short, low-cost allocation using the app's runtime path.
4. Attach with `sherlock-herdr`, detach, and reattach.
5. Start representative Claude and Codex panes and verify detection.
6. End the allocation, start another with the same session name, and confirm restoration.
7. Confirm that a second allocation cannot claim the same active session name.

The final Open OnDemand browser check confirms that the app appears, its defaults are correct, and its session card shows the expected helper command. If browser authentication prevents automation, the user performs this last check after all command-line verification passes.

## Deployment sequence

1. Fetch and record the current commits for upstream and fork `main`.
2. Reset the fork's `main` to upstream with `--force-with-lease`.
3. Create `feature/sh-herdr` from the synchronized upstream commit.
4. Implement and verify the app on that branch.
5. Push the feature branch to `lobennett/sh_ood-apps`; do not open a pull request.
6. Clone or update `~/src/sh_ood-apps` to the feature branch on Sherlock.
7. Run the remote setup command and install the local helper.
8. Add or update the local `sherlock` SSH alias without disturbing unrelated SSH configuration.
9. Verify and remove `~/ondemand/dev/sh_cursor` and `~/ondemand/dev/on_demand_containers`.
10. Link `_common` and `sh_herdr` into `~/ondemand/dev`.
11. Run the smoke test and complete the final browser check.

## Acceptance criteria

- Fork `main` equals `stanford-rc/sh_ood-apps:main` by commit ID.
- The feature branch contains the design, app, helpers, documentation, and tests, with no unrelated fork changes.
- Open OnDemand submits the requested one-node job with `russpold`, 8 CPUs, 32 GB, and 8 hours as defaults and `normal` as an alternative partition.
- The selected Claude/Codex module environment appears in Herdr panes.
- `sherlock-herdr <job-id>` attaches through the `sherlock` alias and the existing Slurm allocation without direct compute-node SSH.
- Detach and reattach work during an allocation.
- Reusing a session name restores Herdr state across allocations.
- Concurrent jobs cannot claim the same session name.
- No credential or listening network service is introduced.
- The two approved legacy development apps are absent from `~/ondemand/dev`.
- No upstream pull request is created.
