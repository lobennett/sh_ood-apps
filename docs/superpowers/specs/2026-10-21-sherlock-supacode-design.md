# Supacode on Sherlock

The user approved a Mac-to-Sherlock workflow and requested a code review, without changes, of the existing Herdr app. Add a separate `sh_supacode` Batch Connect app based on `feature/sh-herdr`.

Supacode runs on the Mac; Open OnDemand owns a finite Slurm allocation on one compute node. Supacode connects to the node's existing SSH service through the Sherlock login node. Claude Code or Codex runs in that allocation against remote files. Do not install a web interface, SSH server, tunnel daemon, or agent supervisor.

## User workflow

1. Select workspace, Claude Code or Codex, partition, CPUs, memory, runtime, and optional modules in OnDemand. Use the existing Herdr defaults for resources (russpold, 8 CPUs, 32 GB, 8 hours).
2. Once ready, the session card shows the node, user, canonical workspace, and one-time SSH configuration. Add a remote repository/folder in Supacode using exactly these values and leave Port blank. Supacode v0.11.5 was inspected: remote repository registration is a GUI operation; `repo open` accepts local paths only.
3. The card's Supacode deeplink opens a new terminal tab in that registered remote workspace and runs the selected agent. Also provide the equivalent terminal command for manually selected worktrees or blocked custom URL schemes.
4. A staged `agent.sh` checks the specified job's live owner, RUNNING state, single node, and current host before initializing modules and invoking the selected CLI. Preserve the terminal's current working directory so newly created worktrees work too. Never weaken agent sandbox/approval settings.
5. Cancel the allocation in OnDemand to end the session. Saved files remain; live processes end with the job. No promise of process survival across allocations. Optional upstream zmx is not installed or required by this app.

## Implementation choices

Keep all per-job metadata and readiness in the existing private Batch Connect staging directory; there is no shared named-session registry or lock. The before hook records canonical paths and identity, the job checks dependencies and holds the allocation, and the after hook reports readiness. Do not change the parent wrapper's shell options from sourced hooks. Retain executable permissions on staged scripts.

Use Bash and Ruby ERB/YAML, matching the repository. URL-encode the remote worktree ID (`user@host` plus canonical path, with root normalized as Supacode does) and shell-quote the staged script path. The connection card uses existing OnDemand Bootstrap classes. No app-specific frontend framework.

SSH setup is explicit in documentation and the connection card; no edits to the user's SSH configuration or shell profiles occur automatically. Supacode's remote Git probes need a current Git in the remote login-shell PATH; validate and document that separately from the agent startup environment.

## Verification

Exercise rendered templates, shell argument quoting, workspace normalization, invalid resources, owner/state/host rejection, missing dependencies, both agents, preserved current worktree, readiness, cancellation, and deeplink decoding. Run existing Herdr tests unchanged and report their limitations. Check deployed versions read-only. A full Mac GUI + OnDemand launch remains unverified until exercised on Sherlock; do not claim otherwise.
