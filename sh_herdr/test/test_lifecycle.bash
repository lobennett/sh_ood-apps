#!/usr/bin/env bash

set -u

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
app_root=$(cd "$test_dir/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/sherlock-herdr-lifecycle.XXXXXX")
fake_bin="$test_root/bin"
home_dir="$test_root/home"
home_herdr_bin="$home_dir/.local/bin/herdr"
home_runtime_library="$home_dir/.local/libexec/sherlock-herdr/runtime.sh"
staging_dir="$test_root/staging"
workspace_dir="$test_root/workspace"
state_root="$test_root/state"
mkdir -p "$fake_bin" "${home_herdr_bin%/*}" "${home_runtime_library%/*}" "$staging_dir" "$workspace_dir"
cp "$app_root/lib/runtime.sh" "$home_runtime_library"

runtime_dir_for_job() {
  printf '/tmp/sherlock-herdr-%s-%s\n' "$UID" "$1"
}

cleanup_test_root() {
  rm -rf "$test_root"
}
trap cleanup_test_root EXIT

# shellcheck source=assertions.bash
source "$test_dir/assertions.bash"

render_template() {
  local template=$1 destination=$2 session=$3 agents=$4 workspace=$5 modules=${6:-} preexec=${7:-}

  TEMPLATE_PATH="$app_root/$template" \
    HERDR_SESSION_VALUE="$session" HERDR_AGENTS_VALUE="$agents" \
    HERDR_WORKSPACE_VALUE="$workspace" HERDR_MODULES_VALUE="$modules" \
    HERDR_PREEXEC_VALUE="$preexec" ruby -rerb <<'RUBY' > "$destination"
class String
  def blank?
    strip.empty?
  end
end

class RenderContext
  attr_reader :herdr_session, :herdr_agents, :sh_workspace, :sh_modules, :sh_preexec

  def initialize
    @herdr_session = ENV.fetch("HERDR_SESSION_VALUE")
    @herdr_agents = ENV.fetch("HERDR_AGENTS_VALUE")
    @sh_workspace = ENV.fetch("HERDR_WORKSPACE_VALUE")
    @sh_modules = ENV.fetch("HERDR_MODULES_VALUE")
    @sh_preexec = ENV.fetch("HERDR_PREEXEC_VALUE")
  end

  def context
    self
  end

  def get_binding
    binding
  end
end

path = ENV.fetch("TEMPLATE_PATH")
renderer = ERB.new(File.read(path), trim_mode: "-")
# Open OnDemand renders development templates from the system dashboard process.
renderer.filename = "/var/www/ood/apps/sys/dashboard"
print renderer.result(RenderContext.new.get_binding)
RUBY
}

cat > "$fake_bin/module" <<'EOF'
#!/usr/bin/env bash
printf 'module %s\n' "$*" >> "${MODULE_LOG:?}"
EOF

cat > "$fake_bin/squeue" <<'EOF'
#!/usr/bin/env bash
tr ',' '\n' <<< "${SQUEUE_ACTIVE_JOBS:-}" | sed '/^$/d'
exit 0
EOF

cat > "$fake_bin/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$fake_bin/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$fake_bin/ruby" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected runtime ruby: %s\n' "$*" >> "${RUBY_LOG:?}"
printf 'ruby: command not found\n' >&2
exit 127
EOF

cat > "$home_herdr_bin" <<'EOF'
#!/usr/bin/env bash
set -u

: "${HERDR_SESSION:?missing HERDR_SESSION}"
: "${HERDR_SOCKET_PATH:?missing HERDR_SOCKET_PATH}"
printf '%s|%s|%s\n' "$HERDR_SESSION" "$HERDR_SOCKET_PATH" "$*" >> "${HERDR_LOG:?}"

case "${1:-}" in
  server)
    if [[ ${2:-} == stop ]]; then
      if [[ -f ${FAKE_SERVER_PID_FILE:?} ]]; then
        kill "$(< "$FAKE_SERVER_PID_FILE")" 2>/dev/null || true
      fi
      exit 0
    fi
    printf '%s\n' "$$" > "${FAKE_SERVER_PID_FILE:?}"
    printf 'fake server started\n'
    trap 'exit 0' TERM INT
    while :; do sleep 0.1; done
    ;;
  status)
    count=0
    [[ -f ${FAKE_STATUS_COUNT_FILE:?} ]] && count=$(< "$FAKE_STATUS_COUNT_FILE")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FAKE_STATUS_COUNT_FILE"
    case ${HERDR_READY_MODE:-false_then_true} in
      false_then_true)
        if (( count == 1 )); then
          printf '{"running":false}\n'
        else
          printf '{"running":true}\n'
        fi
        ;;
      malformed)
        printf '{malformed-json\n'
        kill "$(< "$FAKE_SERVER_PID_FILE")" 2>/dev/null || true
        ;;
      malformed_true)
        printf '{"running":truegarbage}\n'
        kill "$(< "$FAKE_SERVER_PID_FILE")" 2>/dev/null || true
        ;;
      leading_junk)
        printf 'not-json{"running":true}\n'
        kill "$(< "$FAKE_SERVER_PID_FILE")" 2>/dev/null || true
        ;;
      trailing_junk)
        printf '{"running":true}not-json\n'
        kill "$(< "$FAKE_SERVER_PID_FILE")" 2>/dev/null || true
        ;;
      *) exit 2 ;;
    esac
    ;;
  workspace)
    if [[ ${2:-} == list ]]; then
      printf '[]\n'
    fi
    ;;
  *)
    printf 'unexpected Herdr command: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$fake_bin/module" "$fake_bin/squeue" "$fake_bin/claude" "$fake_bin/codex" "$fake_bin/ruby" "$home_herdr_bin"

wait_for_file() {
  local path=$1
  local attempts=${2:-100}
  local _

  for _ in $(seq 1 "$attempts"); do
    [[ -f $path ]] && return 0
    sleep 0.05
  done
  return 1
}

run_job() {
  local before_script=$1 job_script=$2 job_id=$3 mode=$4 output=$5 herdr_override=${6:-}

  (
    cd "$staging_dir"
    # shellcheck disable=SC1090
    source "$before_script"
    export PATH="$fake_bin:/usr/bin:/bin" HOME="$home_dir" SHERLOCK_HERDR_STATE_ROOT="$state_root"
    export SLURM_JOB_ID="$job_id" HERDR_READY_MODE="$mode"
    export MODULE_LOG="$test_root/module.log" HERDR_LOG="$test_root/herdr.log" RUBY_LOG="$test_root/runtime-ruby.log"
    export FAKE_SERVER_PID_FILE="$test_root/server-${job_id}.pid"
    export FAKE_STATUS_COUNT_FILE="$test_root/status-${job_id}.count"
    if [[ -n $herdr_override ]]; then
      export SHERLOCK_HERDR_BIN="$herdr_override"
    else
      unset SHERLOCK_HERDR_BIN
    fi
    exec bash "$job_script"
  ) > "$output" 2>&1 &
  JOB_PID=$!
}

before_script="$test_root/before.sh"
job_script="$test_root/job.sh"
after_script="$test_root/after.sh"
render_template "template/before.sh.erb" "$before_script" sherlock both "$workspace_dir"
render_template "template/script.sh.erb" "$job_script" sherlock both "$workspace_dir"
render_template "template/after.sh.erb" "$after_script" sherlock both "$workspace_dir"
chmod +x "$before_script" "$job_script" "$after_script"

assert_success "rendered before script parses" bash -n "$before_script"
assert_success "rendered job script parses" bash -n "$job_script"
assert_success "rendered after script parses" bash -n "$after_script"
assert_failure "Herdr is absent from the lifecycle PATH" env PATH="$fake_bin:/usr/bin:/bin" command -v herdr

duplicate_job_id=$(( 600000 + $$ ))
mkdir -p "$state_root/sessions/sherlock"
printf '424242\n' > "$state_root/sessions/sherlock/owner_job"
(
  cd "$staging_dir"
  source "$before_script"
  export PATH="$fake_bin:/usr/bin:/bin" HOME="$home_dir" SHERLOCK_HERDR_STATE_ROOT="$state_root"
  export SLURM_JOB_ID="$duplicate_job_id" SQUEUE_ACTIVE_JOBS=424242 HERDR_READY_MODE=false_then_true
  export MODULE_LOG="$test_root/duplicate-module.log" HERDR_LOG="$test_root/duplicate-herdr.log" RUBY_LOG="$test_root/duplicate-ruby.log"
  export FAKE_SERVER_PID_FILE="$test_root/server-duplicate.pid"
  export FAKE_STATUS_COUNT_FILE="$test_root/status-duplicate.count"
  bash "$job_script"
) > "$test_root/duplicate-job.log" 2>&1
assert_failure "active duplicate session fails startup" test "$?" -eq 0
assert_eq "active duplicate lock owner remains" 424242 "$(< "$state_root/sessions/sherlock/owner_job")"
assert_success "active duplicate reports owner job" \
  rg -q "Herdr session sherlock is already owned by Slurm job 424242" "$test_root/duplicate-job.log"
rm -rf "$state_root/sessions/sherlock"

job_id=$(( 700000 + $$ ))
runtime_dir=$(runtime_dir_for_job "$job_id")
[[ ! -e $runtime_dir && ! -L $runtime_dir ]] || {
  printf 'FAIL: lifecycle runtime directory already exists: %s\n' "$runtime_dir" >&2
  exit 1
}
run_job "$before_script" "$job_script" "$job_id" false_then_true "$test_root/job.log"
assert_success "false readiness does not create marker" bash -c 'sleep 0.2; test ! -e "$1"' _ "$staging_dir/herdr-ready"
assert_success "true readiness creates staging marker" wait_for_file "$staging_dir/herdr-ready"
assert_success "server log stays in staging directory" test -f "$staging_dir/herdr-server.log"
assert_failure "workspace has no readiness marker" test -e "$workspace_dir/herdr-ready"
assert_failure "workspace has no server log" test -e "$workspace_dir/herdr-server.log"
assert_success "server log records fake server" rg -q "fake server started" "$staging_dir/herdr-server.log"
assert_success "all lifecycle calls select session and socket from environment" \
  rg -q "^sherlock\|$runtime_dir/herdr.sock\|server$" "$test_root/herdr.log"
assert_failure "lifecycle calls omit explicit session selector" rg -q -- "--session" "$test_root/herdr.log"
assert_failure "rendered lifecycle does not invoke unavailable Ruby" test -e "$test_root/runtime-ruby.log"
assert_success "readiness polled false then true" test "$(< "$test_root/status-${job_id}.count")" -ge 2
if [[ -f $staging_dir/herdr-ready ]]; then
  assert_success "after hook finds exported staging marker from another directory" \
    env herdr_staging_dir="$staging_dir" bash -c 'cd "$1" && bash "$2"' _ "$workspace_dir" "$after_script"
else
  printf 'FAIL: after hook requires a staging readiness marker\n' >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

kill -TERM "$JOB_PID"
kill -TERM "$JOB_PID" 2>/dev/null || true
if wait "$JOB_PID"; then
  printf 'FAIL: repeated signals terminate lifecycle job\n' >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  printf 'PASS: repeated signals terminate lifecycle job\n'
fi
assert_failure "signal cleanup removes job record" test -e "$state_root/jobs/$job_id"
assert_failure "signal cleanup removes session lock" test -e "$state_root/sessions/sherlock"
assert_failure "signal cleanup removes only runtime directory" test -e "$runtime_dir"

malformed_staging="$test_root/malformed-staging"
malformed_workspace="$test_root/malformed-workspace"
mkdir -p "$malformed_staging" "$malformed_workspace"
malformed_before="$test_root/malformed-before.sh"
malformed_job="$test_root/malformed-job.sh"
override_herdr_bin="$test_root/override-herdr"
cat > "$override_herdr_bin" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "\${OVERRIDE_LOG:?}"
exec "$home_herdr_bin" "\$@"
EOF
chmod +x "$override_herdr_bin"
render_template "template/before.sh.erb" "$malformed_before" watson none "$malformed_workspace"
render_template "template/script.sh.erb" "$malformed_job" watson none "$malformed_workspace"
(
  cd "$malformed_staging"
  source "$malformed_before"
  export PATH="$fake_bin:/usr/bin:/bin" HOME="$home_dir" SHERLOCK_HERDR_STATE_ROOT="$state_root"
  export SLURM_JOB_ID="$((job_id + 1))" HERDR_READY_MODE=malformed
  export MODULE_LOG="$test_root/malformed-module.log" HERDR_LOG="$test_root/malformed-herdr.log" RUBY_LOG="$test_root/malformed-ruby.log"
  export SHERLOCK_HERDR_BIN="$override_herdr_bin" OVERRIDE_LOG="$test_root/override-herdr.log"
  export FAKE_SERVER_PID_FILE="$test_root/server-malformed.pid"
  export FAKE_STATUS_COUNT_FILE="$test_root/status-malformed.count"
  exec bash "$malformed_job"
) > "$test_root/malformed-job.log" 2>&1
assert_failure "malformed readiness JSON fails lifecycle startup" test "$?" -eq 0
assert_failure "malformed readiness does not create marker" test -e "$malformed_staging/herdr-ready"
assert_success "malformed readiness reports staging server log" rg -q "fake server started" "$test_root/malformed-job.log"
assert_success "override Herdr path handles lifecycle calls" rg -q "status server --json" "$test_root/override-herdr.log"

malformed_true_staging="$test_root/malformed-true-staging"
malformed_true_workspace="$test_root/malformed-true-workspace"
mkdir -p "$malformed_true_staging" "$malformed_true_workspace"
malformed_true_before="$test_root/malformed-true-before.sh"
malformed_true_job="$test_root/malformed-true-job.sh"
render_template "template/before.sh.erb" "$malformed_true_before" mycroft none "$malformed_true_workspace"
render_template "template/script.sh.erb" "$malformed_true_job" mycroft none "$malformed_true_workspace"
(
  cd "$malformed_true_staging"
  source "$malformed_true_before"
  export PATH="$fake_bin:/usr/bin:/bin" HOME="$home_dir" SHERLOCK_HERDR_STATE_ROOT="$state_root"
  export SLURM_JOB_ID="$((job_id + 2))" HERDR_READY_MODE=malformed_true
  export MODULE_LOG="$test_root/malformed-true-module.log" HERDR_LOG="$test_root/malformed-true-herdr.log" RUBY_LOG="$test_root/malformed-true-ruby.log"
  export FAKE_SERVER_PID_FILE="$test_root/server-malformed-true.pid"
  export FAKE_STATUS_COUNT_FILE="$test_root/status-malformed-true.count"
  exec bash "$malformed_true_job"
) > "$test_root/malformed-true-job.log" 2>&1
assert_failure "malformed true readiness fails lifecycle startup" test "$?" -eq 0
assert_failure "malformed true readiness does not create marker" test -e "$malformed_true_staging/herdr-ready"

run_junk_readiness_case() {
  local label=$1 mode=$2 session=$3 case_job_id=$4
  local case_staging="$test_root/${label}-staging"
  local case_workspace="$test_root/${label}-workspace"
  local case_before="$test_root/${label}-before.sh"
  local case_job="$test_root/${label}-job.sh"
  local case_status

  mkdir -p "$case_staging" "$case_workspace"
  render_template "template/before.sh.erb" "$case_before" "$session" none "$case_workspace"
  render_template "template/script.sh.erb" "$case_job" "$session" none "$case_workspace"
  (
    cd "$case_staging"
    source "$case_before"
    export PATH="$fake_bin:/usr/bin:/bin" HOME="$home_dir" SHERLOCK_HERDR_STATE_ROOT="$state_root"
    export SLURM_JOB_ID="$case_job_id" HERDR_READY_MODE="$mode"
    export MODULE_LOG="$test_root/${label}-module.log" HERDR_LOG="$test_root/${label}-herdr.log" RUBY_LOG="$test_root/${label}-ruby.log"
    export FAKE_SERVER_PID_FILE="$test_root/server-${label}.pid"
    export FAKE_STATUS_COUNT_FILE="$test_root/status-${label}.count"
    exec bash "$case_job"
  ) > "$test_root/${label}-job.log" 2>&1
  case_status=$?
  assert_failure "$label readiness fails lifecycle startup" test "$case_status" -eq 0
  assert_failure "$label readiness does not create marker" test -e "$case_staging/herdr-ready"
}

run_junk_readiness_case leading-junk leading_junk gregson "$((job_id + 3))"
run_junk_readiness_case trailing-junk trailing_junk moriarty "$((job_id + 4))"

missing_agent_before="$test_root/missing-agent-before.sh"
missing_agent_job="$test_root/missing-agent-job.sh"
render_template "template/before.sh.erb" "$missing_agent_before" lestrade claude "$workspace_dir"
render_template "template/script.sh.erb" "$missing_agent_job" lestrade claude "$workspace_dir"
mv "$fake_bin/claude" "$fake_bin/claude.disabled"
(
  cd "$staging_dir"
  source "$missing_agent_before"
  export PATH="$fake_bin:/usr/bin:/bin" HOME="$home_dir" SHERLOCK_HERDR_STATE_ROOT="$state_root" SLURM_JOB_ID="$((job_id + 5))"
  export MODULE_LOG="$test_root/missing-agent-module.log" HERDR_LOG="$test_root/missing-agent-herdr.log" RUBY_LOG="$test_root/missing-agent-ruby.log"
  export FAKE_SERVER_PID_FILE="$test_root/server-missing-agent.pid"
  export FAKE_STATUS_COUNT_FILE="$test_root/status-missing-agent.count"
  bash "$missing_agent_job"
) > "$test_root/missing-agent.log" 2>&1
assert_failure "missing Claude command fails startup" test "$?" -eq 0
mv "$fake_bin/claude.disabled" "$fake_bin/claude"
assert_success "missing Claude command has actionable error" \
  rg -q "Claude command is unavailable after module initialization" "$test_root/missing-agent.log"

canary="$test_root/injection-canary"
injection_before="$test_root/injection-before.sh"
injection_job="$test_root/injection-job.sh"
render_template "template/before.sh.erb" "$injection_before" "safe; touch $canary" both "$workspace_dir"
render_template "template/script.sh.erb" "$injection_job" "safe; touch $canary" both "$workspace_dir" "module; touch $canary"
assert_success "injection rendered lifecycle shell parses" bash -n "$injection_before"
assert_success "injection rendered job shell parses" bash -n "$injection_job"
(
  cd "$staging_dir"
  source "$injection_before"
  export PATH="$fake_bin:/usr/bin:/bin" HOME="$home_dir" SHERLOCK_HERDR_STATE_ROOT="$state_root" SLURM_JOB_ID="$((job_id + 6))"
  export MODULE_LOG="$test_root/injection-module.log" HERDR_LOG="$test_root/injection-herdr.log" RUBY_LOG="$test_root/injection-ruby.log"
  export FAKE_SERVER_PID_FILE="$test_root/server-injection.pid"
  export FAKE_STATUS_COUNT_FILE="$test_root/status-injection.count"
  bash "$injection_job"
) >/dev/null 2>&1
assert_failure "escaped form values do not execute injection canary" test -e "$canary"

finish_tests
