#!/usr/bin/env bash

set -u

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
app_root=$(cd "$test_dir/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/sherlock-herdr-setup.XXXXXX")
install_root="$test_root/install"
fake_bin="$test_root/fake-bin"
fake_state="$test_root/state"
mkdir -p "$fake_bin" "$fake_state"
trap 'rm -rf "$test_root"' EXIT

source "$test_dir/assertions.bash"

assert_file_mode() {
  local description=$1 path=$2 expected=$3 actual
  actual=$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path" 2>/dev/null || true)
  assert_eq "$description" "$expected" "$actual"
}

assert_file_contains() {
  local description=$1 path=$2 expected=$3
  if [[ -f $path ]] && grep -Fq -- "$expected" "$path"; then
    printf 'PASS: %s\n' "$description"
  else
    printf 'FAIL: %s (expected %q in %s)\n' "$description" "$expected" "$path" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
  fi
}

cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${CURL_LOG:?}"
output=
while (( $# > 0 )); do
  case $1 in
    -o) output=$2; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n $output ]]
if [[ ${CURL_FAIL:-0} == 1 ]]; then
  printf 'incomplete installer\n' > "$output"
  exit 22
fi
cat > "$output" <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${SHERLOCK_HERDR_INSTALL_ROOT:?}/bin"
cat > "${SHERLOCK_HERDR_INSTALL_ROOT}/bin/herdr" <<'HERDR'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --version ]]; then
  if [[ ${HERDR_VERSION_FAIL:-0} == 1 ]]; then
    exit 7
  fi
  printf 'herdr test 1.2.3\n'
elif [[ ${1:-} == update ]]; then
  printf '%s\n' "$*" > "${CAPTURED_HERDR_ARGS:?}"
fi
HERDR
chmod 755 "${SHERLOCK_HERDR_INSTALL_ROOT}/bin/herdr"
INSTALLER
chmod 755 "$output"
EOF

cat > "$fake_bin/mktemp" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/mktemp "$@"
EOF
chmod 755 "$fake_bin/curl" "$fake_bin/mktemp"

export HOME="$test_root/home"
export PATH="$fake_bin:$PATH"
export SHERLOCK_HERDR_INSTALL_ROOT="$install_root"
export SHERLOCK_HERDR_BIN="$install_root/bin/herdr"
export SHERLOCK_HERDR_INSTALL_URL='https://example.invalid/install.sh'
export CURL_LOG="$fake_state/curl.log"
export CAPTURED_HERDR_ARGS="$fake_state/herdr.args"

# Existing Herdr is updated and the helper payload is installed atomically.
mkdir -p "$install_root/bin"
cat > "$install_root/bin/herdr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --version ]]; then
  printf 'herdr existing 9.9.9\n'
elif [[ ${1:-} == update ]]; then
  printf '%s\n' "$*" > "${CAPTURED_HERDR_ARGS:?}"
fi
EOF
chmod 755 "$install_root/bin/herdr"
: > "$CURL_LOG"
setup_output="$test_root/setup.output"
if "$app_root/bin/setup" > "$setup_output" 2>&1; then
  printf 'PASS: existing Herdr setup succeeds\n'
else
  printf 'FAIL: existing Herdr setup succeeds\n' >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
assert_file_mode "installed attachment helper is executable" "$install_root/bin/sherlock-herdr-attach" 755
assert_file_mode "installed runtime library is non-executable" "$install_root/libexec/sherlock-herdr/runtime.sh" 644
assert_file_contains "update branch invokes Herdr update" "$CAPTURED_HERDR_ARGS" 'update'
if [[ ! -s $CURL_LOG ]]; then
  printf 'PASS: existing Herdr skips download\n'
else
  printf 'FAIL: existing Herdr skips download\n' >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
assert_file_contains "output shows attachment command" "$setup_output" 'sherlock-herdr <job-id>'
assert_file_contains "output shows SSH alias" "$setup_output" 'Host sherlock'
assert_file_contains "output shows Herdr version" "$setup_output" 'herdr existing 9.9.9'
assert_file_contains "output shows local helper install" "$setup_output" 'scp sherlock:'

# A missing Herdr is installed from a downloaded file, then verified.
rm -f "$install_root/bin/herdr" "$install_root/bin/sherlock-herdr-attach" \
  "$install_root/libexec/sherlock-herdr/runtime.sh"
: > "$CURL_LOG"
unset CURL_FAIL
if "$app_root/bin/setup" > "$test_root/fresh.output" 2>&1; then
  printf 'PASS: fresh Herdr setup succeeds\n'
else
  printf 'FAIL: fresh Herdr setup succeeds\n' >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
assert_file_contains "fresh setup verifies Herdr version" "$test_root/fresh.output" 'herdr test 1.2.3'
assert_file_contains "fresh setup downloads installer URL" "$CURL_LOG" "$SHERLOCK_HERDR_INSTALL_URL"
assert_file_mode "fresh attachment helper mode" "$install_root/bin/sherlock-herdr-attach" 755
assert_file_mode "fresh runtime library mode" "$install_root/libexec/sherlock-herdr/runtime.sh" 644

# Version verification failure does not leave newly staged helper payloads.
rm -f "$install_root/bin/sherlock-herdr-attach" "$install_root/libexec/sherlock-herdr/runtime.sh"
export HERDR_VERSION_FAIL=1
if "$app_root/bin/setup" > "$test_root/version-failure.output" 2>&1; then
  printf 'FAIL: failed Herdr version exits nonzero\n' >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  printf 'PASS: failed Herdr version exits nonzero\n'
fi
if [[ ! -e $install_root/bin/sherlock-herdr-attach &&
      ! -e $install_root/libexec/sherlock-herdr/runtime.sh ]]; then
  printf 'PASS: failed Herdr version leaves no helper payload\n'
else
  printf 'FAIL: failed Herdr version leaves no helper payload\n' >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
unset HERDR_VERSION_FAIL

# A failed download does not leave helper or runtime payloads behind.
rm -f "$install_root/bin/herdr" "$install_root/bin/sherlock-herdr-attach" \
  "$install_root/libexec/sherlock-herdr/runtime.sh"
export CURL_FAIL=1
if "$app_root/bin/setup" > "$test_root/failure.output" 2>&1; then
  printf 'FAIL: failed download exits nonzero\n' >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  printf 'PASS: failed download exits nonzero\n'
fi
if [[ ! -e $install_root/bin/sherlock-herdr-attach &&
      ! -e $install_root/libexec/sherlock-herdr/runtime.sh ]]; then
  printf 'PASS: failed download leaves no partial helper payload\n'
else
  printf 'FAIL: failed download leaves no partial helper payload\n' >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

finish_tests
