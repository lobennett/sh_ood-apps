#!/usr/bin/env bash
set -u

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
app_root=$(cd "$test_dir/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/sherlock-herdr-helpers.XXXXXX")
fake_bin="$test_root/bin"
mkdir -p "$fake_bin" "$test_root/home/.local/libexec/sherlock-herdr" "$test_root/home/.local/bin"
trap 'rm -rf "$test_root"' EXIT

source "$test_dir/assertions.bash"
export HOME="$test_root/home" SHERLOCK_HERDR_STATE_ROOT="$test_root/state" PATH="$fake_bin:$PATH"
cp "$app_root/lib/runtime.sh" "$HOME/.local/libexec/sherlock-herdr/runtime.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "${SRUN_LOG:?}"\n' > "$HOME/.local/bin/herdr"
chmod +x "$HOME/.local/bin/herdr"

cat > "$fake_bin/ssh" <<'EOF'
#!/usr/bin/env bash
{ printf 'ssh'; for arg in "$@"; do printf '|%s' "$arg"; done; printf '\n'; } > "${SSH_LOG:?}"
EOF
cat > "$fake_bin/squeue" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${SQUEUE_OUTPUT:-}"
EOF
cat > "$fake_bin/srun" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${SRUN_LOG:?}"
EOF
chmod +x "$fake_bin/ssh" "$fake_bin/squeue" "$fake_bin/srun"

assert_command_fails() {
  local description=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s\n' "$description" >&2; TEST_FAILURES=$((TEST_FAILURES + 1))
  else printf 'PASS: %s\n' "$description"; fi
}
assert_command_output() {
  local description=$1 expected=$2; shift 2
  local output
  output=$(SSH_LOG="$test_root/ssh.log" "$@" 2>/dev/null || true)
  output=$(<"$test_root/ssh.log")
  if [[ $output == "$expected" ]]; then printf 'PASS: %s\n' "$description"; else printf 'FAIL: %s (expected %q, got %q)\n' "$description" "$expected" "$output" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); fi
}

assert_command_fails "missing job id" "$app_root/bin/sherlock-herdr"
assert_command_fails "malformed job id" "$app_root/bin/sherlock-herdr" '12;uname'
assert_command_output "ssh command" 'ssh|-tt|sherlock|~/.local/bin/sherlock-herdr-attach|12345' "$app_root/bin/sherlock-herdr" 12345

source "$HOME/.local/libexec/sherlock-herdr/runtime.sh"
write_job_record 12345 sherlock '/tmp/sherlock-herdr-'"$UID"'-12345/herdr.sock' sh03-01n01
export SQUEUE_OUTPUT="12345|$USER|RUNNING" SRUN_LOG="$test_root/srun.log"
assert_success "remote attachment" "$app_root/bin/sherlock-herdr-attach" 12345
assert_eq "srun arguments" '--jobid=12345 --overlap --nodes=1 --ntasks=1 --nodelist=sh03-01n01 --pty env HERDR_SOCKET_PATH=/tmp/sherlock-herdr-'"$UID"'-12345/herdr.sock '"$HOME/.local/bin/herdr"' --session sherlock' "$(<"$SRUN_LOG")"

export SQUEUE_OUTPUT="12345|foreign|RUNNING"; assert_command_fails "foreign owner" "$app_root/bin/sherlock-herdr-attach" 12345
export SQUEUE_OUTPUT="12345|$USER|PENDING"; assert_command_fails "pending job" "$app_root/bin/sherlock-herdr-attach" 12345
export SQUEUE_OUTPUT=; assert_command_fails "missing job" "$app_root/bin/sherlock-herdr-attach" 12345
rm -f "$(job_record_path 12345)"; export SQUEUE_OUTPUT="12345|$USER|RUNNING"; assert_command_fails "missing registry" "$app_root/bin/sherlock-herdr-attach" 12345
write_job_record 12345 'bad/session' '/tmp/sherlock-herdr-'"$UID"'-12345/herdr.sock' sh03-01n01 2>/dev/null || true
printf 'bad/session\t/tmp/sherlock-herdr-%s-12345/herdr.sock\tsh03-01n01\n' "$UID" > "$(job_record_path 12345)" 2>/dev/null || true
assert_command_fails "invalid stored session" "$app_root/bin/sherlock-herdr-attach" 12345
printf 'sherlock\t/tmp/untrusted/herdr.sock\tsh03-01n01\n' > "$(job_record_path 12345)"
assert_command_fails "socket outside runtime directory" "$app_root/bin/sherlock-herdr-attach" 12345

finish_tests
