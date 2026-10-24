#!/usr/bin/env bash
# Exercise bin/setup against a fake git and a fake agentic-engineering checkout.
set -u

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
app_root=$(cd "$test_dir/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/sh-ae-setup.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
failures=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
assert_eq() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
assert_contains() { if [[ -f $2 ]] && grep -Fq -- "$3" "$2"; then pass "$1"; else fail "$1 (expected '$3' in $2)"; fi; }
assert_missing() { if [[ ! -e $2 ]]; then pass "$1"; else fail "$1 ($2 exists)"; fi; }

fake_bin="$test_root/bin"
mkdir -p "$fake_bin" "$test_root/home"
cat > "$fake_bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GIT_LOG:?}"
case ${1:-} in
  clone)
    [[ ${GIT_CLONE_FAIL:-0} == 0 ]] || { echo 'fatal: clone failed' >&2; exit 128; }
    target=${*: -1}
    mkdir -p "$target/.git"
    printf '%s\n' "${*: -2:1}" > "$target/.git/origin"
    if [[ ${GIT_CLONE_WITHOUT_ENTRY:-0} == 0 ]]; then
      cat > "$target/setup.sh" <<'SETUP'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${SETUP_LOG:?}"
printf 'AE_FIRSTMATE_DIR=%s\nAE_BIN_DIR=%s\n' "${AE_FIRSTMATE_DIR:-}" "${AE_BIN_DIR:-}" >> "$SETUP_LOG"
exit "${SETUP_EXIT:-0}"
SETUP
    fi
    ;;
  config) cat .git/origin ;;
  pull) [[ ${GIT_PULL_FAIL:-0} == 0 ]] || { echo 'fatal: Not possible to fast-forward' >&2; exit 128; } ;;
  *) echo "unexpected git $*" >&2; exit 2 ;;
esac
GIT
chmod 755 "$fake_bin/git"

export PATH="$fake_bin:/usr/bin:/bin"
export HOME="$test_root/home"
export GIT_LOG="$test_root/git.log" SETUP_LOG="$test_root/setup.log"
export AGENTIC_ENGINEERING_CHECKOUT="$test_root/home/src/agentic-engineering"
unset AE_FIRSTMATE_DIR AE_BIN_DIR AGENTIC_ENGINEERING_REPO_URL SETUP_EXIT GIT_CLONE_FAIL GIT_PULL_FAIL GIT_CLONE_WITHOUT_ENTRY

# Fresh run clones, then runs setup.sh with the given arguments and defaults.
: > "$GIT_LOG"
"$app_root/bin/setup" --check > "$test_root/fresh.out" 2>&1
assert_eq "fresh setup succeeds" 0 "$?"
assert_contains "fresh setup clones the public repository" "$GIT_LOG" "clone -- https://github.com/lobennett/agentic-engineering.git $AGENTIC_ENGINEERING_CHECKOUT"
assert_contains "setup.sh receives the arguments" "$SETUP_LOG" "--check"
assert_contains "setup.sh sees the default Firstmate home" "$SETUP_LOG" "AE_FIRSTMATE_DIR=$HOME/firstmate"
assert_contains "setup.sh sees the default Herdr directory" "$SETUP_LOG" "AE_BIN_DIR=$HOME/.local/bin"
assert_contains "fresh setup prints the install-apps step" "$test_root/fresh.out" "install-apps.sh"
assert_contains "fresh setup names the Firstmate home" "$test_root/fresh.out" "Firstmate home: $HOME/firstmate"

# A second run fast-forwards instead of cloning and passes user overrides through.
: > "$GIT_LOG"; : > "$SETUP_LOG"
AE_FIRSTMATE_DIR="$test_root/elsewhere/fm" AE_BIN_DIR="$test_root/elsewhere/bin" \
  "$app_root/bin/setup" --yes --skip-skills > "$test_root/repeat.out" 2>&1
assert_eq "repeat setup succeeds" 0 "$?"
assert_contains "repeat setup fast-forwards" "$GIT_LOG" "pull --ff-only"
if grep -q '^clone' "$GIT_LOG"; then fail "repeat setup does not clone again"; else pass "repeat setup does not clone again"; fi
assert_contains "repeat setup passes several arguments" "$SETUP_LOG" "--yes --skip-skills"
assert_contains "repeat setup honors AE_FIRSTMATE_DIR" "$SETUP_LOG" "AE_FIRSTMATE_DIR=$test_root/elsewhere/fm"

# setup.sh failures propagate their exit status.
SETUP_EXIT=2 "$app_root/bin/setup" > "$test_root/status.out" 2>&1
assert_eq "setup.sh exit status propagates" 2 "$?"
assert_contains "setup.sh failure is reported" "$test_root/status.out" "setup.sh exited with status 2"

# A diverged checkout is reported, not forced.
GIT_PULL_FAIL=1 "$app_root/bin/setup" > "$test_root/diverged.out" 2>&1
assert_eq "diverged checkout fails" 1 "$?"
assert_contains "diverged checkout explains" "$test_root/diverged.out" "Could not fast-forward"

# A checkout tracking another repository is refused and left alone.
printf 'https://example.invalid/other.git\n' > "$AGENTIC_ENGINEERING_CHECKOUT/.git/origin"
: > "$GIT_LOG"
"$app_root/bin/setup" > "$test_root/foreign.out" 2>&1
assert_eq "foreign checkout is refused" 1 "$?"
assert_contains "foreign checkout names both remotes" "$test_root/foreign.out" "tracks https://example.invalid/other.git, not"
if grep -q 'pull' "$GIT_LOG"; then fail "foreign checkout is not updated"; else pass "foreign checkout is not updated"; fi

# A plain directory at the checkout path is refused.
rm -rf "$AGENTIC_ENGINEERING_CHECKOUT"; mkdir -p "$AGENTIC_ENGINEERING_CHECKOUT"
"$app_root/bin/setup" > "$test_root/plain.out" 2>&1
assert_eq "non-git directory is refused" 1 "$?"
assert_contains "non-git directory explains" "$test_root/plain.out" "is not a Git checkout"
rm -rf "$AGENTIC_ENGINEERING_CHECKOUT"

# A checkout without the documented entry point fails clearly.
GIT_CLONE_WITHOUT_ENTRY=1 "$app_root/bin/setup" > "$test_root/noentry.out" 2>&1
assert_eq "missing setup.sh fails" 1 "$?"
assert_contains "missing setup.sh is explained" "$test_root/noentry.out" "setup.sh is missing"
rm -rf "$AGENTIC_ENGINEERING_CHECKOUT"

# Clone failures and a missing git are reported.
GIT_CLONE_FAIL=1 "$app_root/bin/setup" > "$test_root/clonefail.out" 2>&1
assert_eq "clone failure fails" 1 "$?"
assert_contains "clone failure is explained" "$test_root/clonefail.out" "Could not clone"
assert_missing "clone failure leaves no setup.sh" "$AGENTIC_ENGINEERING_CHECKOUT/setup.sh"
nogit_bin="$test_root/nogit"
mkdir -p "$nogit_bin"
for tool in bash dirname mkdir cat; do
  ln -s "$(command -v "$tool")" "$nogit_bin/$tool"
done
PATH="$nogit_bin" "$app_root/bin/setup" > "$test_root/nogit.out" 2>&1
assert_eq "missing git fails" 1 "$?"
assert_contains "missing git suggests the module" "$test_root/nogit.out" "module load system git"

"$app_root/bin/setup" --help > "$test_root/help.out" 2>&1
assert_eq "help exits zero" 0 "$?"
assert_contains "help documents the checkout variable" "$test_root/help.out" "AGENTIC_ENGINEERING_CHECKOUT"

if (( failures == 0 )); then printf 'All setup tests passed.\n'; else printf '%d setup test(s) failed.\n' "$failures" >&2; exit 1; fi
