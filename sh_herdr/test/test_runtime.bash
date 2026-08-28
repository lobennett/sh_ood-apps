#!/usr/bin/env bash

set -u

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ ${0##*/} == squeue ]]; then
  job_id=
  while (( $# > 0 )); do
    case $1 in
      -j)
        job_id=$2
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  case ",${SQUEUE_ACTIVE_JOBS:-}," in
    *",${job_id},"*) printf 'RUNNING\n' ;;
  esac
  exit 0
fi

test_root=$(mktemp -d "${TMPDIR:-/tmp}/sherlock-herdr-runtime.XXXXXX")
fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
ln -s "$test_dir/test_runtime.bash" "$fake_bin/squeue"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

export SHERLOCK_HERDR_STATE_ROOT="$test_root/state"
export PATH="$fake_bin:$PATH"

# This file intentionally does not exist during the RED run.
# shellcheck source=../lib/runtime.sh
source "$test_dir/../lib/runtime.sh"
source "$test_dir/assertions.bash"

assert_eq "configured state root" "$test_root/state" "$(state_root)"
assert_success "create private state root" ensure_state_root
assert_eq "state root mode" 700 "$(stat -f '%Lp' "$(state_root)" 2>/dev/null || stat -c '%a' "$(state_root)")"
assert_success "numeric job id" validate_job_id 12345
assert_failure "reject job id suffix" validate_job_id '123;id'
assert_success "safe session" validate_session_name sherlock.work-1
assert_failure "reject slash" validate_session_name '../work'
assert_failure "reject dot" validate_session_name '.'
assert_eq "job record path" "$test_root/state/jobs/12345" "$(job_record_path 12345)"
assert_eq "session lock path" "$test_root/state/sessions/sherlock" "$(session_lock_path sherlock)"
assert_eq "expected runtime directory" "/tmp/sherlock-herdr-$UID-12345" "$(expected_runtime_dir 12345)"
assert_eq "expected socket path" "/tmp/sherlock-herdr-$UID-12345/herdr.sock" "$(expected_socket_path 12345)"

write_job_record 12345 sherlock \
  '/tmp/sherlock-herdr-501-12345/herdr.sock' 'sh03-01n01'
IFS=$'\t' read -r actual_session actual_socket actual_host < "$(job_record_path 12345)"
assert_eq "recorded session" sherlock "$actual_session"
assert_eq "recorded socket" '/tmp/sherlock-herdr-501-12345/herdr.sock' "$actual_socket"
assert_eq "recorded host" sh03-01n01 "$actual_host"
assert_eq "record mode" 600 "$(stat -f '%Lp' "$(job_record_path 12345)" 2>/dev/null || stat -c '%a' "$(job_record_path 12345)")"
assert_eq "read job record" $'sherlock\t/tmp/sherlock-herdr-501-12345/herdr.sock\tsh03-01n01' "$(read_job_record 12345)"
assert_failure "reject tab in socket record field" write_job_record 77777 sherlock $'/tmp/herdr.sock\tother' sh03-01n01
assert_failure "reject mismatched socket path" write_job_record 77778 sherlock '/tmp/untrusted/herdr.sock' sh03-01n01

assert_success "first lock claim" acquire_session_lock sherlock 12345
assert_eq "first lock owner" 12345 "$(< "$(session_lock_path sherlock)/owner_job")"

export SQUEUE_ACTIVE_JOBS=12345
assert_failure "duplicate active owner" acquire_session_lock sherlock 54321
assert_eq "active lock owner remains" 12345 "$(< "$(session_lock_path sherlock)/owner_job")"

export SQUEUE_ACTIVE_JOBS=
assert_success "stale owner reclamation" acquire_session_lock sherlock 54321
assert_eq "reclaimed lock owner" 54321 "$(< "$(session_lock_path sherlock)/owner_job")"

mkdir "$(session_lock_path missing-owner)"
assert_failure "missing lock owner is busy" acquire_session_lock missing-owner 65432
assert_success "missing-owner lock remains" test -d "$(session_lock_path missing-owner)"

mkdir "$(session_lock_path malformed-owner)"
printf 'not-a-job\n' > "$(session_lock_path malformed-owner)/owner_job"
assert_failure "malformed lock owner is busy" acquire_session_lock malformed-owner 65432
assert_success "malformed-owner lock remains" test -d "$(session_lock_path malformed-owner)"

write_job_record 44444 wrong-owner '/tmp/sherlock-herdr-501-44444/herdr.sock' sh03-01n01
assert_success "wrong-owner cleanup returns" release_job_state sherlock 44444
assert_eq "wrong-owner lock remains" 54321 "$(< "$(session_lock_path sherlock)/owner_job")"
assert_success "wrong-owner record remains" test -f "$(job_record_path 44444)"

write_job_record 54321 sherlock '/tmp/sherlock-herdr-501-54321/herdr.sock' sh03-01n01
assert_success "owner cleanup" release_job_state sherlock 54321
assert_failure "owner lock removed" test -e "$(session_lock_path sherlock)"
assert_failure "owner record removed" test -e "$(job_record_path 54321)"
assert_success "idempotent owner cleanup" release_job_state sherlock 54321

runtime_job_id=$$
runtime_dir=$(expected_runtime_dir "$runtime_job_id")
other_runtime_dir="$test_root/runtime"
if [[ -e $runtime_dir || -L $runtime_dir ]]; then
  printf 'FAIL: test runtime directory already exists: %s\n' "$runtime_dir" >&2
  exit 1
fi
mkdir -p "$runtime_dir"
mkdir -p "$other_runtime_dir"
assert_failure "reject different runtime directory" remove_runtime_dir "$runtime_job_id" "$other_runtime_dir"
assert_success "remove expected runtime directory" remove_runtime_dir "$runtime_job_id" "$runtime_dir"
assert_failure "expected runtime directory removed" test -e "$runtime_dir"
assert_success "different runtime directory remains" test -d "$other_runtime_dir"

finish_tests
