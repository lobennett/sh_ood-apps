# Sherlock Herdr Open OnDemand Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, test, publish, and deploy an Open OnDemand app that runs a persistent named Herdr session in a Sherlock Slurm allocation and attaches to it from a local terminal with `sherlock-herdr <job-id>`.

**Architecture:** Open OnDemand submits a one-node Batch Connect job that loads Sherlock's `claude-code` and/or `codex` modules, starts a named Herdr server, and records private job metadata in `$HOME`. Herdr keeps durable state in `$HOME` and its live Unix socket in a private node-local `/tmp` directory. A local helper reaches the login node through the `sherlock` SSH alias; a remote helper verifies job ownership and uses `srun --overlap --pty` to attach inside the existing allocation.

**Tech Stack:** Bash, ERB, YAML, Ruby Minitest, Open OnDemand Batch Connect, Slurm, Lmod, OpenSSH, Herdr.

**Spec:** `docs/superpowers/specs/2026-08-28-sherlock-herdr-ondemand-design.md`

## Global Constraints

- Fork `main` must equal `stanford-rc/sh_ood-apps:main`; all new work lives on `feature/sh-herdr`.
- Do not open an upstream pull request.
- The app requests one node and exposes no TCP listener, reverse proxy, browser shell, or credential.
- Form defaults are session `sherlock`, agents `Both`, partition `russpold`, 8 CPUs, 32 GB, and 8 hours; `normal` is the only alternative partition.
- Sherlock agent modules are `claude-code` and `codex`; selected command checks are `claude` and `codex`.
- Job IDs are decimal digits only. Session names match `^[A-Za-z0-9][A-Za-z0-9._-]*$` and cannot be `.` or `..`.
- Runtime state uses mode `0700` for directories and `0600` for files.
- Durable Herdr state stays in `$HOME`; the live socket is `/tmp/sherlock-herdr-<uid>-<job-id>/herdr.sock`.
- The local helper uses the SSH alias `sherlock`; it never accepts a hostname, user, socket path, or session name from the command line.
- Remote attachment verifies the Slurm job exists, is `RUNNING`, and belongs to the current Sherlock user before invoking `srun`.
- Cleanup removes state only when the current job still owns it and leaves Herdr's durable session data intact.
- Delete only the verified Sherlock paths `~/ondemand/dev/sh_cursor` and `~/ondemand/dev/on_demand_containers`.

---

## File map

- `sh_herdr/lib/runtime.sh`: validation, registry, lock, stale-lock, and ownership-aware cleanup functions shared by the batch job and remote helper.
- `sh_herdr/bin/sherlock-herdr`: local macOS/Linux entry point; validates the job ID and invokes SSH.
- `sh_herdr/bin/sherlock-herdr-attach`: trusted Sherlock-side attachment entry point; validates Slurm and registry state and invokes `srun`.
- `sh_herdr/bin/setup`: installs/updates Herdr and installs the remote helper plus runtime library under `~/.local`.
- `sh_herdr/form.yml.erb`: user-visible job and Herdr options.
- `sh_herdr/form.js`: symlink to `../_common/form.js` for the workspace picker.
- `sh_herdr/manifest.yml`: Open OnDemand app metadata.
- `sh_herdr/submit.yml.erb`: Batch Connect connection parameters and Slurm resources.
- `sh_herdr/template/before.sh.erb`: exports validated connection parameters before the server starts.
- `sh_herdr/template/script.sh.erb`: loads modules, claims the session, starts Herdr, creates the initial workspace, and owns cleanup.
- `sh_herdr/template/after.sh.erb`: waits for the server-ready marker.
- `sh_herdr/view.html.erb`: displays job/session details and the copyable helper command.
- `sh_herdr/README.md`: user setup, authentication, launch, attach, restore, and troubleshooting instructions.
- `sh_herdr/test/assertions.bash`: dependency-free Bash test assertions.
- `sh_herdr/test/test_runtime.bash`: runtime registry and locking tests.
- `sh_herdr/test/test_helpers.bash`: local and remote helper tests with fake commands.
- `sh_herdr/test/test_setup.bash`: setup/install tests in an isolated directory.
- `sh_herdr/test/test_templates.rb`: ERB/YAML and connection-view tests using Ruby stdlib.
- `sh_herdr/test/run`: complete local test entry point.

---

### Task 1: Runtime state, validation, and locks

**Files:**
- Create: `sh_herdr/lib/runtime.sh`
- Create: `sh_herdr/test/assertions.bash`
- Create: `sh_herdr/test/test_runtime.bash`

**Interfaces:**
- Produces: `validate_job_id VALUE`, `validate_session_name VALUE`, `state_root`, `ensure_state_root`, `job_record_path JOB_ID`, `session_lock_path SESSION`, `expected_runtime_dir JOB_ID`, `expected_socket_path JOB_ID`, `write_job_record JOB_ID SESSION SOCKET HOST`, `read_job_record JOB_ID`, `acquire_session_lock SESSION JOB_ID`, `release_job_state SESSION JOB_ID`, and `remove_runtime_dir JOB_ID PATH`.
- Record format: one tab-separated line containing `session`, `socket`, and `host`.
- Lock owner format: one decimal job ID followed by a newline in `sessions/<session>/owner_job`.

- [ ] **Step 1: Write the validation and registry tests**

Create a dependency-free test harness with `assert_success`, `assert_failure`, `assert_eq`, and `finish_tests`. Add these concrete cases to `test_runtime.bash`:

```bash
assert_success "numeric job id" validate_job_id 12345
assert_failure "reject job id suffix" validate_job_id '123;id'
assert_success "safe session" validate_session_name sherlock.work-1
assert_failure "reject slash" validate_session_name '../work'
assert_failure "reject dot" validate_session_name '.'

write_job_record 12345 sherlock \
  '/tmp/sherlock-herdr-501-12345/herdr.sock' 'sh03-01n01'
IFS=$'\t' read -r actual_session actual_socket actual_host < "$(job_record_path 12345)"
assert_eq "recorded session" sherlock "$actual_session"
assert_eq "recorded socket" '/tmp/sherlock-herdr-501-12345/herdr.sock' "$actual_socket"
assert_eq "record mode" 600 "$(stat -f '%Lp' "$(job_record_path 12345)" 2>/dev/null || stat -c '%a' "$(job_record_path 12345)")"
```

Use `SHERLOCK_HERDR_STATE_ROOT="$test_root/state"` and a fake `squeue` on `PATH`. Add lock cases for first claim, duplicate active owner, stale owner reclamation, wrong-owner cleanup, and idempotent owner cleanup.

- [ ] **Step 2: Run the runtime tests and confirm they fail**

Run: `bash sh_herdr/test/test_runtime.bash`

Expected: FAIL because `sh_herdr/lib/runtime.sh` does not exist.

- [ ] **Step 3: Implement the runtime library**

Implement the public functions with this contract:

```bash
validate_job_id() {
  [[ ${1:-} =~ ^[0-9]+$ ]]
}

validate_session_name() {
  local value=${1:-}
  [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] &&
    [[ $value != '.' && $value != '..' ]]
}

state_root() {
  printf '%s\n' "${SHERLOCK_HERDR_STATE_ROOT:-$HOME/.local/state/sherlock-herdr}"
}
```

`ensure_state_root` must set `umask 077`, create `jobs` and `sessions`, and enforce mode `0700`. `write_job_record` must write a temporary file in `jobs`, `chmod 0600` it, then atomically `mv` it into place. `acquire_session_lock` must use `mkdir` as the atomic claim; when a lock exists, it reads `owner_job`, treats a missing or malformed owner as busy, and calls `squeue -h -j "$owner_job" -o '%T'`. A non-empty Slurm response means busy. An empty response permits an atomic rename to `sessions/.stale-<session>-<job>-<pid>`, removal of that renamed directory, and one retry. `release_job_state` must compare owner IDs before renaming and removing a lock or job record. `remove_runtime_dir` must require its path to equal `expected_runtime_dir JOB_ID` before removing it.

- [ ] **Step 4: Run the runtime tests**

Run: `bash sh_herdr/test/test_runtime.bash`

Expected: all validation, registry, lock, stale-lock, mode, and cleanup assertions PASS.

- [ ] **Step 5: Commit the runtime unit**

```bash
git add sh_herdr/lib/runtime.sh sh_herdr/test/assertions.bash sh_herdr/test/test_runtime.bash
git commit -m "feat: add Herdr session state management"
```

---

### Task 2: Local and Sherlock attachment helpers

**Files:**
- Create: `sh_herdr/bin/sherlock-herdr`
- Create: `sh_herdr/bin/sherlock-herdr-attach`
- Create: `sh_herdr/test/test_helpers.bash`

**Interfaces:**
- Consumes: runtime validation and `read_job_record` from Task 1.
- Produces: local command `sherlock-herdr JOB_ID`; remote command `sherlock-herdr-attach JOB_ID`.
- Remote command invokes: `srun --jobid=JOB_ID --overlap --nodes=1 --ntasks=1 --nodelist=HOST --pty env HERDR_SESSION=SESSION HERDR_SOCKET_PATH=SOCKET HERDR_BIN`.

- [ ] **Step 1: Write failing helper tests with fake `ssh`, `squeue`, and `srun`**

The local-helper assertions must include:

```bash
assert_command_fails "missing job id" "$app_root/bin/sherlock-herdr"
assert_command_fails "malformed job id" "$app_root/bin/sherlock-herdr" '12;uname'
assert_command_output "ssh command" \
  'ssh|-tt|sherlock|~/.local/bin/sherlock-herdr-attach|12345' \
  "$app_root/bin/sherlock-herdr" 12345
```

The remote-helper fakes must return `12345|$USER|RUNNING` from `squeue` and capture `srun` arguments. Assert the exact argument vector contains the job, overlap mode, one node/task, recorded host, pseudo-terminal flag, recorded socket, Herdr binary, and session. Add failures for a foreign owner, `PENDING`, missing job, missing registry, invalid stored session, and a socket outside `/tmp/sherlock-herdr-<uid>-<job-id>/herdr.sock`.

- [ ] **Step 2: Run the helper tests and confirm they fail**

Run: `bash sh_herdr/test/test_helpers.bash`

Expected: FAIL because both helper commands are absent.

- [ ] **Step 3: Implement the local helper**

Use this complete behavior:

```bash
#!/usr/bin/env bash
set -euo pipefail

job_id=${1:-}
if [[ $# -ne 1 || ! $job_id =~ ^[0-9]+$ ]]; then
  printf 'Usage: sherlock-herdr JOB_ID\n' >&2
  exit 2
fi

exec ssh -tt sherlock '~/.local/bin/sherlock-herdr-attach' "$job_id"
```

- [ ] **Step 4: Implement the remote helper**

Source the installed runtime library from `~/.local/libexec/sherlock-herdr/runtime.sh`. Query `squeue -h -j "$job_id" -o '%i|%u|%T'`, parse exactly one row, require the current `id -un` and `RUNNING`, then read and validate the registry. Require the socket to equal `/tmp/sherlock-herdr-$(id -u)-${job_id}/herdr.sock`. Resolve Herdr as `${SHERLOCK_HERDR_BIN:-$HOME/.local/bin/herdr}` and `exec srun` with the interface above. Print one-line actionable errors and use exit 2 for usage, 3 for authorization/state, and 4 for registry/runtime failures.

- [ ] **Step 5: Run helper tests**

Run: `bash sh_herdr/test/test_helpers.bash`

Expected: all helper and injection-resistance assertions PASS.

- [ ] **Step 6: Commit the attachment helpers**

```bash
git add sh_herdr/bin/sherlock-herdr sh_herdr/bin/sherlock-herdr-attach sh_herdr/test/test_helpers.bash
git commit -m "feat: attach to Herdr through an existing Slurm job"
```

---

### Task 3: Setup command and isolated installation tests

**Files:**
- Create: `sh_herdr/bin/setup`
- Create: `sh_herdr/test/test_setup.bash`

**Interfaces:**
- Consumes: `bin/sherlock-herdr-attach` and `lib/runtime.sh`.
- Produces: `~/.local/bin/herdr`, `~/.local/bin/sherlock-herdr-attach`, and `~/.local/libexec/sherlock-herdr/runtime.sh`.

- [ ] **Step 1: Write failing setup tests**

Use an isolated `SHERLOCK_HERDR_INSTALL_ROOT` and fake `herdr`, `curl`, and installer commands. Assert that setup:

```bash
assert_file_mode "$install_root/bin/sherlock-herdr-attach" 755
assert_file_mode "$install_root/libexec/sherlock-herdr/runtime.sh" 644
assert_file_contains "$captured_herdr_args" 'update'
assert_file_contains "$setup_output" 'sherlock-herdr <job-id>'
```

Add the missing-Herdr case: fake `curl` writes an installer that creates `bin/herdr`; setup then verifies `herdr --version`. Add a failed-download case that exits nonzero without installing partial helper files.

- [ ] **Step 2: Run setup tests and confirm they fail**

Run: `bash sh_herdr/test/test_setup.bash`

Expected: FAIL because `bin/setup` is absent.

- [ ] **Step 3: Implement setup**

`setup` must:

1. Use `${SHERLOCK_HERDR_INSTALL_ROOT:-$HOME/.local}`.
2. Download `https://herdr.dev/install.sh` to a `mktemp -d` directory only when Herdr is absent.
3. Run the downloaded installer as a file, never through `curl | sh`.
4. Run `herdr update` when Herdr already exists.
5. Install the remote helper with mode `0755` and runtime library with mode `0644` using temporary files followed by `mv`.
6. Print `herdr --version`, the expected SSH alias, and the local helper installation command.

Allow tests to override the installer URL with `SHERLOCK_HERDR_INSTALL_URL` and the Herdr path with `SHERLOCK_HERDR_BIN`; do not expose either option in the OnDemand form.

- [ ] **Step 4: Run setup tests**

Run: `bash sh_herdr/test/test_setup.bash`

Expected: all fresh-install, update, permissions, output, and failed-download assertions PASS.

- [ ] **Step 5: Commit setup**

```bash
git add sh_herdr/bin/setup sh_herdr/test/test_setup.bash
git commit -m "feat: add one-time Herdr setup command"
```

---

### Task 4: Open OnDemand form, manifest, and Slurm submission

**Files:**
- Create: `sh_herdr/manifest.yml`
- Create: `sh_herdr/form.yml.erb`
- Create: `sh_herdr/form.js` as symlink to `../_common/form.js`
- Create: `sh_herdr/submit.yml.erb`
- Create: `sh_herdr/test/test_templates.rb`

**Interfaces:**
- Produces form values: `herdr_session`, `herdr_agents`, `sh_workspace`, `bc_queue`, `sh_cpus`, `sh_mem`, `bc_num_hours`, `sh_modules`, `sh_preexec`, and `bc_email_on_started`.
- Produces connection parameters: `herdr_session` and `herdr_workspace`.

- [ ] **Step 1: Write failing Ruby template tests**

Use Ruby stdlib `erb`, `yaml`, and `minitest/autorun`. Define `String#blank?`, `NilClass#blank?`, and a binding object exposing the form variables. Add these exact assertions:

```ruby
form = YAML.safe_load(render("form.yml.erb"))
assert_equal "sherlock", form.dig("attributes", "herdr_session", "value")
assert_equal "both", form.dig("attributes", "herdr_agents", "value")
assert_equal "russpold", form.dig("attributes", "bc_queue", "value")
assert_equal [["russpold", "russpold"], ["normal", "normal"]],
             form.dig("attributes", "bc_queue", "options")
assert_equal 8, form.dig("attributes", "sh_cpus", "value")
assert_equal 32, form.dig("attributes", "sh_mem", "value")
assert_equal 8, form.dig("attributes", "bc_num_hours", "value")

submit = YAML.safe_load(render("submit.yml.erb", sh_cpus: "12", sh_mem: "48"))
assert_equal "basic", submit.dig("batch_connect", "template")
assert_equal %w[herdr_session herdr_workspace], submit.dig("batch_connect", "conn_params")
assert_includes submit.dig("script", "native"), "12"
assert_includes submit.dig("script", "native"), "48G"
```

- [ ] **Step 2: Run the template tests and confirm they fail**

Run: `ruby sh_herdr/test/test_templates.rb`

Expected: ERROR because the app templates do not exist.

- [ ] **Step 3: Create the manifest, form, and form helper symlink**

The manifest name is `Herdr`, category `Interactive Apps`, subcategory `Development`, role `batch_connect`, and description states that the app launches a persistent agent workspace on a Sherlock compute node.

The form must explicitly define the fields instead of importing all of `_common`, because it intentionally omits GPUs and restricts partitions. Use `bc_queue` as a predefined field so Open OnDemand passes the selected partition to Slurm. Define its options as exactly `russpold` and `normal`. Mark session, agents, workspace, partition, CPUs, memory, and runtime required. Use the existing `data-filepicker` attributes for `sh_workspace`. Label `sh_preexec` as advanced and state that its commands execute as the user.

Create the symlink with:

```bash
ln -s ../_common/form.js sh_herdr/form.js
```

- [ ] **Step 4: Create the submission template**

Use `batch_connect.template: basic` and `conn_params: [herdr_session, herdr_workspace]`. Match existing Sherlock apps for one node and resource arguments:

```yaml
script:
  native:
    - "-N"
    - "1"
    - "-c"
    - "<%= sh_cpus.blank? ? 8 : sh_cpus.to_i %>"
    - "--mem"
    - "<%= sh_mem.blank? ? 32 : sh_mem.to_i %>G"
```

Do not duplicate partition or wall-time arguments: Open OnDemand maps `bc_queue` and `bc_num_hours` into the script options.

- [ ] **Step 5: Run the template tests**

Run: `ruby sh_herdr/test/test_templates.rb`

Expected: manifest, form defaults/options, connection parameters, and Slurm resource assertions PASS.

- [ ] **Step 6: Commit the Open OnDemand form and submission unit**

```bash
git add sh_herdr/manifest.yml sh_herdr/form.yml.erb sh_herdr/form.js sh_herdr/submit.yml.erb sh_herdr/test/test_templates.rb
git commit -m "feat: add Herdr Open OnDemand job form"
```

---

### Task 5: Batch runtime, readiness, connection view, and cleanup

**Files:**
- Create: `sh_herdr/template/before.sh.erb`
- Create: `sh_herdr/template/script.sh.erb`
- Create: `sh_herdr/template/after.sh.erb`
- Create: `sh_herdr/view.html.erb`
- Modify: `sh_herdr/test/test_templates.rb`
- Modify: `sh_herdr/test/test_runtime.bash`

**Interfaces:**
- Consumes: Task 1 runtime functions and Task 4 form values.
- Produces: marker and server log rooted in the Batch Connect staging directory captured by `before.sh.erb`, plus custom connection values `herdr_session` and `herdr_workspace`.
- Starts server with: `HERDR_SESSION=SESSION HERDR_SOCKET_PATH=SOCKET herdr server`. Herdr 0.8.2 resolves an explicit `--session` before `HERDR_SOCKET_PATH`, so lifecycle and attach commands must not combine those two selectors.

- [ ] **Step 1: Add failing render and runtime assertions**

Render the templates with session `sherlock`, agents `both`, and workspace `/home/users/test/work`. Assert:

```ruby
assert_includes before_script, "export herdr_session=sherlock"
assert_includes before_script, "export herdr_workspace=/home/users/test/work"
assert_includes job_script, "module load claude-code codex"
assert_includes job_script, "HERDR_SOCKET_PATH"
assert_includes job_script, "HERDR_SESSION"
assert_includes after_script, "herdr-ready"
assert_includes view, "sherlock-herdr"
assert_includes view, "session.job_id"
refute_includes view, "/rnode/"
```

Add shell tests proving cleanup refuses mismatched ownership, removes matching job and lock state on repeated calls, rejects an unexpected runtime path, and removes only `expected_runtime_dir JOB_ID`.

- [ ] **Step 2: Run targeted tests and confirm they fail**

Run:

```bash
ruby sh_herdr/test/test_templates.rb
bash sh_herdr/test/test_runtime.bash
```

Expected: FAIL on missing lifecycle templates and cleanup behavior.

- [ ] **Step 3: Implement `before.sh.erb`**

Use Ruby `Shellwords.escape` for the session and workspace form values. Export lowercase `herdr_session` and `herdr_workspace` for Batch Connect `conn_params`. Do not export tokens or credentials.

- [ ] **Step 4: Implement `script.sh.erb`**

The script must use `set -euo pipefail` and perform this sequence:

```bash
module reset
module load system git
case <%= Shellwords.escape(context.herdr_agents.to_s) %> in
  both) module load claude-code codex ;;
  claude) module load claude-code ;;
  codex) module load codex ;;
  none) ;;
  *) printf 'Invalid agent environment\n' >&2; exit 2 ;;
esac
```

Then load optional modules, execute the raw advanced initialization block, validate the workspace/session/job ID, and verify selected commands. Source `lib/runtime.sh` using the absolute application path generated by ERB. Create `/tmp/sherlock-herdr-$(id -u)-${SLURM_JOB_ID}` with mode `0700`, set the socket path, claim the session, and write the registry.

Install an idempotent trap that first runs `HERDR_SESSION="$session" HERDR_SOCKET_PATH="$socket" herdr server stop`, then performs bounded waits, terminates only the recorded server PID if necessary, and always calls `release_job_state "$session" "$SLURM_JOB_ID"` and `remove_runtime_dir "$SLURM_JOB_ID" "$runtime_dir"`. Ignore repeated `INT`/`TERM` signals after cleanup begins so they cannot interrupt state release.

Start the server in the background, poll for at most 120 seconds with:

```bash
HERDR_SESSION="$session" HERDR_SOCKET_PATH="$socket" herdr status server --json
```

Parse the returned JSON and require `running` to be exactly `true`; exit status alone is not readiness. If the server exits, JSON is malformed, or the timeout expires, print the staging-directory server log and fail. Once ready, create an initial workspace only when `workspace list` contains no `workspace_id`, using `workspace create --cwd "$workspace" --label "$(basename "$workspace")" --no-focus`. Touch the staging-directory readiness marker, then `wait` for the server process.

- [ ] **Step 5: Implement readiness and connection view**

`before.sh.erb` captures and exports the Batch Connect staging directory before the job script changes directories. `after.sh.erb` polls that absolute directory for `herdr-ready` for 120 seconds, exits successfully when present, and calls `clean_up 1` after printing the server log on timeout.

`view.html.erb` must HTML-escape the session and workspace, display `session.job_id`, and render this command as text:

```erb
<code>sherlock-herdr <%= ERB::Util.html_escape(session.job_id.to_s) %></code>
```

Include short setup and detach instructions. Do not create a form, URL, password, or reverse-proxy link.

- [ ] **Step 6: Run lifecycle tests**

Run:

```bash
ruby sh_herdr/test/test_templates.rb
bash sh_herdr/test/test_runtime.bash
```

Expected: all lifecycle, escaping, no-proxy, readiness, and cleanup assertions PASS.

- [ ] **Step 7: Commit the Batch Connect runtime**

```bash
git add sh_herdr/template sh_herdr/view.html.erb sh_herdr/test
git commit -m "feat: run persistent Herdr sessions in Batch Connect jobs"
```

---

### Task 6: User documentation and complete local verification

**Files:**
- Create: `sh_herdr/README.md`
- Create: `sh_herdr/test/run`
- Modify: `README.md`

**Interfaces:**
- Consumes: all app commands and files from Tasks 1–5.
- Produces: one command, `sh_herdr/test/run`, for local verification.

- [ ] **Step 1: Create the complete test runner**

`sh_herdr/test/run` must use `set -euo pipefail` and run, in order:

```bash
bash "$test_dir/test_runtime.bash"
bash "$test_dir/test_helpers.bash"
bash "$test_dir/test_setup.bash"
ruby "$test_dir/test_templates.rb"
```

If `shellcheck` exists, run it against every regular shell file under `sh_herdr/bin`, `sh_herdr/lib`, `sh_herdr/template`, and `sh_herdr/test`, excluding ERB files. If it is absent, print a single skip line.

- [ ] **Step 2: Write app documentation**

Document:

1. Running `bash ~/src/sh_ood-apps/sh_herdr/bin/setup` on Sherlock.
2. Installing the local helper with `scp sherlock:~/src/sh_ood-apps/sh_herdr/bin/sherlock-herdr ~/.local/bin/` and `chmod 755 ~/.local/bin/sherlock-herdr`.
3. The exact `Host sherlock`, `HostName`, and `User logben` example, labeled as a personal example whose user must be changed by other users.
4. Authenticating `claude` and `codex` in a normal Sherlock compute session before launching agents.
5. Launching the OnDemand app, copying the job ID, attaching, detaching, reattaching, and canceling the allocation.
6. Named-session restoration and the duplicate-name rule.
7. Logs, common module/setup failures, allocation expiry, and registry location.
8. Security: no browser shell, open port, or stored credential.

Add `sh_herdr` to the repository root README's app list.

- [ ] **Step 3: Run complete local verification**

Run:

```bash
bash sh_herdr/test/run
git diff --check
git status --short
```

Expected: all tests PASS, no whitespace errors, and only intended app/docs changes remain.

- [ ] **Step 4: Commit documentation and verification entry point**

```bash
git add README.md sh_herdr/README.md sh_herdr/test/run
git commit -m "docs: explain Sherlock Herdr workflow"
```

---

### Task 7: Synchronize the fork and publish the feature branch

**Files:**
- No file changes.

**Interfaces:**
- Consumes: verified local `feature/sh-herdr` and fetched `origin/main` plus `upstream/main`.
- Produces: fork `main` equal to upstream and remote `feature/sh-herdr` containing only upstream plus this feature.

- [ ] **Step 1: Fetch and re-verify divergence**

Run:

```bash
git fetch origin main
git fetch upstream main
git rev-list --left-right --count upstream/main...origin/main
git log --oneline --left-right --cherry-pick upstream/main...origin/main
```

Expected before reset: upstream-only commits `7bce8a7` and `f2cb5a8`; fork-only commits `6265957` and `4e00ca2`, unless GitHub changed after planning. If it changed, stop and inspect rather than reusing the recorded lease.

- [ ] **Step 2: Record the lease and force-reset fork `main`**

Run:

```bash
fork_main_before=$(git rev-parse origin/main)
git push --force-with-lease=refs/heads/main:"$fork_main_before" \
  origin upstream/main:refs/heads/main
```

Expected: GitHub reports a forced update from the recorded fork commit to upstream `main`.

- [ ] **Step 3: Verify exact history equality**

Run:

```bash
git fetch origin main
test "$(git rev-parse origin/main)" = "$(git rev-parse upstream/main)"
git rev-list --left-right --count upstream/main...origin/main
```

Expected: equality test exits 0 and count is `0  0`.

- [ ] **Step 4: Push the feature branch without opening a PR**

Run:

```bash
git push -u origin feature/sh-herdr
```

Expected: remote branch created or updated; no `gh pr create` command is run.

---

### Task 8: Deploy to Sherlock and install the local helper

**Files:**
- Remote clone: `~/src/sh_ood-apps`
- Remote links: `~/ondemand/dev/_common`, `~/ondemand/dev/sh_herdr`
- Local install: `~/.local/bin/sherlock-herdr`
- Local SSH configuration: `~/.ssh/config`

**Interfaces:**
- Consumes: remote `feature/sh-herdr` and SSH alias `sherlock`.
- Produces: visible Sherlock development app and working local helper.

- [ ] **Step 1: Establish an authenticated SSH control connection**

Run locally and complete normal Stanford password/Duo prompts:

```bash
ssh -M -S /tmp/codex-sherlock-logben.sock \
  -o ControlPersist=30m -fN logben@login.sherlock.stanford.edu
```

Expected: control socket exists and `ssh -S /tmp/codex-sherlock-logben.sock logben@login.sherlock.stanford.edu true` succeeds.

- [ ] **Step 2: Inspect exact deployment targets before mutation**

Through the control socket, inspect `~/src/sh_ood-apps`, `~/ondemand/dev/_common`, `~/ondemand/dev/sh_cursor`, `~/ondemand/dev/on_demand_containers`, and `~/ondemand/dev/sh_herdr` with `ls -ld`, `readlink`, Git status, and remote URLs where applicable. Stop if any path resolves outside the user's home directory.

- [ ] **Step 3: Clone or fast-forward the feature checkout**

If `~/src/sh_ood-apps` is absent:

```bash
git clone --branch feature/sh-herdr \
  https://github.com/lobennett/sh_ood-apps.git "$HOME/src/sh_ood-apps"
```

If it is the expected clean clone, fetch and use `git switch feature/sh-herdr` plus `git pull --ff-only`. Do not reset an unrelated or dirty checkout.

- [ ] **Step 4: Verify Sherlock modules and run remote setup**

Run:

```bash
module spider claude-code
module spider codex
module load claude-code codex
command -v claude
command -v codex
bash "$HOME/src/sh_ood-apps/sh_herdr/bin/setup"
"$HOME/.local/bin/herdr" --version
```

Expected: both modules resolve, both commands are callable, setup succeeds, and Herdr prints a version.

- [ ] **Step 5: Remove only the approved legacy apps and create links**

Resolve each legacy path with `realpath`, require exact equality with the two approved home paths, then remove those exact directories:

```bash
legacy_cursor="$HOME/ondemand/dev/sh_cursor"
legacy_containers="$HOME/ondemand/dev/on_demand_containers"
test "$(realpath "$legacy_cursor")" = "$legacy_cursor"
test "$(realpath "$legacy_containers")" = "$legacy_containers"
rm -rf -- "$legacy_cursor" "$legacy_containers"
```

If `_common` is a copied directory, require `diff -qr "$HOME/ondemand/dev/_common" "$HOME/src/sh_ood-apps/_common"` to succeed before removing that exact directory. Stop for review if it differs. Then create links:

```bash
ln -s "$HOME/src/sh_ood-apps/_common" "$HOME/ondemand/dev/_common"
ln -s "$HOME/src/sh_ood-apps/sh_herdr" "$HOME/ondemand/dev/sh_herdr"
```

Expected: `readlink -f` for both links points into `~/src/sh_ood-apps`, and both legacy app paths are absent.

- [ ] **Step 6: Install the local helper and SSH alias**

Install the helper from the local feature checkout:

```bash
install -m 0755 sh_herdr/bin/sherlock-herdr "$HOME/.local/bin/sherlock-herdr"
```

Inspect `~/.ssh/config`. If `Host sherlock` is absent, append exactly:

```sshconfig
Host sherlock
  HostName login.sherlock.stanford.edu
  User logben
```

If the alias exists, preserve unrelated settings and update only a conflicting `HostName` or `User` after showing the diff.

- [ ] **Step 7: Verify deployment paths**

Run local and remote checks:

```bash
ssh -G sherlock | rg '^(hostname|user) '
ssh sherlock 'readlink -f "$HOME/ondemand/dev/sh_herdr"; readlink -f "$HOME/ondemand/dev/_common"; "$HOME/.local/bin/herdr" --version'
```

Expected: alias resolves to `login.sherlock.stanford.edu` and `logben`; links resolve to the feature checkout; Herdr prints its version.

---

### Task 9: Sherlock compute-node smoke test and final verification

**Files:**
- No source changes unless the smoke test exposes a defect; any fix returns to its owning task's tests and receives a focused commit.

**Interfaces:**
- Consumes: deployed app, local helper, authenticated SSH, Sherlock modules, and Slurm.
- Produces: evidence for attachment, persistence, concurrency protection, and Open OnDemand visibility.

- [ ] **Step 1: Run all source verification again at the published commit**

Run locally:

```bash
bash sh_herdr/test/run
git diff --check
git status --short --branch
git log --oneline upstream/main..HEAD
```

Expected: all tests PASS, worktree clean, and the feature branch contains only design/app commits above upstream.

- [ ] **Step 2: Submit a short allocation through the development app**

Open `https://ondemand.sherlock.stanford.edu`, choose the development `Herdr` app, and submit these values: session `sherlock-smoke`, agents `Both`, workspace `$HOME`, partition `russpold`, 2 CPUs, 8 GB, and 0.5 hours. Record the Slurm job ID shown on the session card. Do not substitute a login-node Herdr process.

Expected: job reaches `RUNNING`, the registry record exists with mode `0600`, the runtime directory is `0700`, and `herdr status server --json` succeeds inside the allocation.

- [ ] **Step 3: Attach, detach, and reattach**

Run locally:

```bash
sherlock-herdr JOB_ID
```

Inside Herdr, confirm the initial workspace path and run `command -v claude` plus `command -v codex` in a pane. Detach with `Ctrl-B`, then `Q`, and run the same helper command again.

Expected: both commands resolve, the same workspace returns, and the allocation remains running between attachments.

- [ ] **Step 4: Verify duplicate-session protection and restoration**

While the first job owns session `sherlock-smoke`, submit a second short job with the same name and confirm it fails with the owning job ID. End the first allocation, start a new one with session `sherlock-smoke`, and confirm Herdr restores its workspace state. Use `sherlock-smoke-2` once to confirm independent allocations remain possible.

- [ ] **Step 5: Complete the authenticated browser check**

Open Sherlock OnDemand, confirm `Herdr` appears under development interactive apps, inspect the form defaults and partition choices, launch a session, and confirm its card shows the expected job ID, session, workspace, and `sherlock-herdr <job-id>` command.

- [ ] **Step 6: Final repository and deployment audit**

Run:

```bash
git fetch origin main feature/sh-herdr
test "$(git rev-parse origin/main)" = "$(git rev-parse upstream/main)"
test "$(git rev-parse origin/feature/sh-herdr)" = "$(git rev-parse feature/sh-herdr)"
git status --short --branch
```

On Sherlock, verify the two legacy app paths are absent, the two deployment links are correct, no test allocation remains, and the session registry contains no orphaned active lock.

Expected: fork `main` equals upstream, the feature branch equals the tested local commit, the local worktree is clean, deployment is correct, and no upstream pull request exists.
