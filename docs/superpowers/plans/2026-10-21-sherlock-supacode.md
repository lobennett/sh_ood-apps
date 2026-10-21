# Sherlock Supacode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add an OnDemand allocation and agent launcher for Supacode on a Mac, and report the existing Herdr review separately.

**Architecture:** The Batch Connect job validates its workspace and dependencies, publishes connection metadata, and holds a finite allocation. A staged agent script checks live Slurm ownership and node identity before loading modules and executing the CLI from the current worktree. The session card supplies SSH setup, Supacode registration fields, a launch deeplink, and a terminal fallback.

**Tech Stack:** Bash, Ruby ERB, YAML, Python standard-library test orchestration.

**Spec:** `docs/superpowers/specs/2026-10-21-sherlock-supacode-design.md`

## Global Constraints

- Mac UI, existing Sherlock SSH service, single-node Slurm job; no new SSH or web server.
- Defaults: russpold, 8 CPUs, 32 GB, 8 hours. Agent choice: Claude Code or Codex.
- Preserve Herdr unchanged. No deployments, profile edits, or agent authentication as part of local implementation.
- Staged script must retain the selected Supacode worktree directory.
- No live-process persistence promise after job end.

## Review Focus

- SSH-created shells do not inherit modules from the Batch Connect job.
- Old system Git cannot manage remote worktrees; login-shell Git needs its own prerequisite check.
- Paths with spaces, quotes, ampersands, or percent signs must survive Ruby, HTML, URL, and shell boundaries.
- An expired, foreign, pending, malformed, or wrong-node job must never launch an agent.
- Readiness hooks must return to the OnDemand wrapper; cancellation must remove stale readiness without affecting workspace files.

### Task 1: Allocation, connection card, and agent launcher

**Files:** Create `sh_supacode/{manifest.yml,form.yml.erb,submit.yml.erb,view.html.erb}`, `sh_supacode/template/{before.sh.erb,script.sh.erb,after.sh.erb,agent.sh.erb}`, and `sh_supacode/test/{render.rb,test_app.py,run}`. Reuse `_common/bc_js_filepicker-3.0.2.js` through `form.js`.

**Interfaces:** Connection params are `supacode_job_id`, `supacode_host`, `supacode_user`, `supacode_workspace`, `supacode_staging_dir`, `supacode_agent`. `bash -l STAGING/agent.sh JOB_ID` starts the selected agent from the current directory. `agent.sh --check` validates dependencies inside the allocation without running an agent.

- [x] Write behavior tests for rendered form/submission/view, launch rejection cases, dependency setup, current-directory preservation, lifecycle readiness/cancellation, and shell/HTML/URL injection boundaries.
- [x] Run `bash sh_supacode/test/run`; expect failure because the templates do not exist.
- [x] Implement the templates and launch flow; invalid values fail with actionable errors.
- [x] Run `bash sh_supacode/test/run`; expect all tests passing, including rendered Bash syntax checks.
- [x] Commit the implementation and its tests.

### Task 2: Setup documentation and independent review

**Files:** Create `sh_supacode/README.md`, update root `README.md`, and add `docs/reviews/2026-10-21-herdr.md`.

**Interfaces:** Documentation uses the actual connection fields and staged command from Task 1, plus verified upstream Supacode v0.11.5 behavior and live Sherlock module checks.

- [x] Document install/symlink steps, one-time SSH and login-shell Git prerequisites, remote registration, button/fallback behavior, auth ownership, worktree use, cancellation, and remaining live checks.
- [x] Record reproducible Herdr findings without modifying that app.
- [x] Run both app suites and `git diff --check`; report any skipped checks.
- [x] Have a fresh reviewer inspect the new app and tests. Resolve material findings with a failing regression test before the fix.
- [ ] Commit and push the new feature branch and open a draft PR against the Herdr feature branch, leaving main and deployed Sherlock untouched.
