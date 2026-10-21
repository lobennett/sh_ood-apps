# Supacode on Sherlock

`sh_supacode` reserves a finite, single-node Sherlock Slurm allocation through
Open OnDemand. Supacode runs on your Mac and connects to the allocated node
over SSH through the login node. The connection card launches Claude Code or
Codex in a Supacode terminal on that node.

This is not a browser-hosted Supacode server. Supacode's remote repository
support is beta. Its GUI and deeplink behavior were checked against **0.11.5**;
use that release or a newer compatible version on macOS 26+. No agent, SSH
server, or web server is installed by this app.

## Install the OnDemand app

Keep the whole repository together: `form.js` links to the existing `_common`
file picker. On Sherlock, from the checkout containing this app:

```bash
mkdir -p "$HOME/ondemand/dev"
ln -s "$HOME/src/sh_ood-apps/sh_supacode" "$HOME/ondemand/dev/sh_supacode"
```

Adjust the checkout path if necessary. Do not replace an existing app link
without checking where it points. The app appears in OnDemand's development
apps. No separate helper installation is needed; OnDemand stages `agent.sh`
with each job.

## One-time SSH and Git setup

On your Mac, keep your existing `sherlock` SSH alias and add the compute-node
block. Replace `YOUR_SUNET_ID` with your account:

```sshconfig
Host sherlock
  HostName login.sherlock.stanford.edu
  User YOUR_SUNET_ID

Host sh??-*n*
  User YOUR_SUNET_ID
  ProxyJump sherlock
```

SSH access to a compute node requires an active allocation on that node.
Use Sherlock's existing SSH service. Do not start your own SSH server.

Supacode runs its remote Git commands in a login shell. That shell needs a Git
version that supports worktrees; Sherlock's default system Git was **1.8.3.1**
when checked on 2026-10-21. In your existing Sherlock Bash login profile
(`~/.bash_profile`), load the provided modern Git module:

```bash
module load system git
```

This is a one-time user setup step; the app does not edit shell profiles.
Keep existing profile initialization intact. Check from your Mac:

```bash
ssh sherlock 'bash -lc "git --version; git worktree -h"'
```

The module provided Git 2.45.1 when checked. Loading Git only in the OnDemand
job does **not** fix Supacode's separate SSH shells. If you use another login
shell, configure its equivalent login profile. Supacode also needs remote
`gh` for its optional GitHub features; those are not required to start agents.

Authenticate the agent CLI on Sherlock in a normal interactive compute
session before using the app. The provided module names are `claude-code` and
`codex`. Authentication and permission settings remain managed by those CLIs;
this app never collects credentials or passes sandbox-bypass flags.

## Start a session

1. In OnDemand, choose **Supacode**. Choose the agent and a repository or folder.
   The default allocation is `russpold`, 8 CPUs, 32 GB, and 8 hours; reduce or
   increase resources for your actual work. `normal` is also available.
2. Launch and wait for the session card. Startup checks the workspace, selected
   modules, and agent executable. It does not start an agent before you connect.
3. Use the node and user shown on the card to SSH once from your Mac. Complete
   normal authentication and host-key verification. Keep the host-key checks
   enabled; unfamiliar compute nodes may need first-use confirmation.
4. In Supacode, choose **Connect to Remote Host**. Enter the card's **Server**,
   **User**, and **Path** exactly and leave **Port** blank. These values identify
   the remote worktree used by the launch button.
5. After the workspace appears, click **Launch Claude Code/Codex in Supacode**
   on the OnDemand card. Allow the browser to open Supacode and confirm the
   supplied command if prompted. This creates a new tab; clicking again starts
   another agent, rather than reattaching an existing tab.

Supacode 0.11.5's `repo open` CLI/deeplink supports local paths only, so the
initial remote registration is deliberately a GUI step. The app does not
modify Supacode's private configuration files.

If the browser blocks the custom URL scheme or you registered a different
alias/user/port, copy the card's terminal command instead. Run it in the
desired **remote** Supacode terminal. It checks that the original job is
running, belongs to you, and is assigned to the node where the terminal is
running. It then loads the agent and extra modules in that terminal and
launches the agent. Pending, ended, foreign, malformed, and wrong-node jobs
are rejected.

For parallel work, create worktrees in Supacode and run the same command in
each worktree's terminal. The launcher preserves the current working
directory. All agents share the allocation's CPUs and memory.

## End, reconnect, and diagnose

Cancel the session from OnDemand or use `scancel JOB_ID`. The allocation's
processes end, but saved repository files and agent-owned configuration
remain. This app does not preserve processes across allocations or install
zmx. Upstream Supacode session persistence requires zmx on the remote host;
without it, do not assume an SSH disconnect preserves your terminal process.

A new allocation may use another node. Update the remote connection in
Supacode using the new card, then use its new launch command. Never reuse an
old card's command after its allocation ends.

Startup logs and metadata live only in the Batch Connect staging directory:
`supacode-startup.log`, `supacode-job-id`, `supacode-host`, and readiness/failure
markers. Agent output appears in the Supacode terminal. There is no shared
named-session registry or credential store.

| Symptom | Action |
| --- | --- |
| Cannot add the remote repository | Check the active allocation, SSH config, authentication, and host-key confirmation in a Mac terminal first. |
| Git/worktree errors | Check the remote **login-shell** Git version and module setup above. |
| Launch button does nothing | Register the exact server/user/path with Port blank, or paste the terminal fallback in the selected remote worktree. |
| Job starts but is not ready | Open `supacode-startup.log`; correct missing modules, executable, or workspace. |
| Agent opens in the wrong environment | Use the card's `bash -l .../agent.sh JOB_ID` command so the module system initializes in the SSH shell. |
| Agent authentication fails | Complete that CLI's own sign-in on Sherlock; do not put credentials in the app form. |

## Verification

```bash
bash sh_supacode/test/run
```

The tests render the real ERB templates and execute the lifecycle and launcher
against controlled scheduler/module/agent boundaries. They cover both agents,
ownership/state/host checks, dependency failures, quoting, worktree paths,
deeplink decoding, readiness, and cancellation cleanup.

The complete GUI path (OnDemand staging, SSH authentication, Supacode remote
registration, launch button, and Slurm cancellation) still needs a live
acceptance run. Read-only checks confirmed the installed Sherlock modules;
the automated compute-node SSH probe stopped at host-key verification rather
than bypassing it.

References: [Supacode 0.11.5 SSH implementation](https://github.com/supabitapp/supacode/blob/v0.11.5/SupacodeSettingsShared/Support/SSHCommand.swift),
[remote repository UI](https://github.com/supabitapp/supacode/blob/v0.11.5/supacode/Features/Repositories/Views/RemoteConnectionFormView.swift),
[deeplinks](https://github.com/supabitapp/supacode/blob/v0.11.5/Resources/Skills/supacode-deeplinks.md),
[Sherlock compute-node access](https://www.sherlock.stanford.edu/docs/user-guide/running-jobs/#connecting-to-nodes).
