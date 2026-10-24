#!/usr/bin/env bash
# Exercise install-apps.sh with a throwaway HOME. The real checkout is the
# (read-only) source of apps.
set -u

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$test_dir/.." && pwd -P)
installer="$repo_root/install-apps.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/sh-ood-install.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
export HOME="$test_root/home"
mkdir -p "$HOME"
dev="$HOME/ondemand/dev"
failures=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
assert_eq() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
assert_link() {
  local description=$1 link=$2 expected=$3
  if [[ -L $link && $(readlink -- "$link") == "$expected" ]]; then pass "$description"; else fail "$description ($link -> $(readlink -- "$link" 2>/dev/null || echo '<none>'))"; fi
}
assert_contains() { if grep -Fq -- "$2" "$3"; then pass "$1"; else fail "$1 (expected '$2' in $3)"; fi; }
assert_absent() { if [[ ! -e $2 && ! -L $2 ]]; then pass "$1"; else fail "$1 ($2 exists)"; fi; }
default_apps=(sh_agentic-engineering sh_herdr sh_marimo sh_supacode)

# A fresh install creates ~/ondemand/dev and links the default apps.
"$installer" > "$test_root/fresh.out" 2>&1
assert_eq "fresh install exits zero" 0 "$?"
assert_contains "fresh install creates the sandbox directory" "created $dev" "$test_root/fresh.out"
for app in "${default_apps[@]}"; do
  assert_link "fresh install links $app" "$dev/$app" "$repo_root/$app"
done
assert_absent "fresh install leaves system-provided apps alone" "$dev/sh_jupyterlab"
assert_contains "fresh install explains the Develop menu" "Develop -> My Sandbox Apps" "$test_root/fresh.out"
assert_contains "fresh install names the site-side prerequisite" "Enabling App Development" "$test_root/fresh.out"
assert_eq "linked app resolves its manifest" "yes" "$([[ -f $dev/sh_agentic-engineering/manifest.yml ]] && echo yes)"
assert_eq "linked app reaches the shared form JavaScript" "yes" "$([[ -f $dev/sh_agentic-engineering/form.js ]] && echo yes)"

# Repeating the install is a no-op.
"$installer" > "$test_root/repeat.out" 2>&1
assert_eq "repeat install exits zero" 0 "$?"
assert_contains "repeat install reports already installed" "sh_herdr: already installed" "$test_root/repeat.out"
if grep -q 'linked' "$test_root/repeat.out"; then fail "repeat install links nothing"; else pass "repeat install links nothing"; fi

# An equivalent symlink spelled differently still counts as installed.
rm "$dev/sh_marimo"; ln -s "$repo_root/sh_marimo/" "$dev/sh_marimo"
"$installer" > "$test_root/equiv.out" 2>&1
assert_eq "equivalent symlink is accepted" 0 "$?"
assert_contains "equivalent symlink reports already installed" "sh_marimo: already installed" "$test_root/equiv.out"

# A real directory or a foreign symlink is a conflict; other apps still install.
rm "$dev/sh_marimo" "$dev/sh_herdr" "$dev/sh_supacode"
mkdir "$dev/sh_marimo"; touch "$dev/sh_marimo/keep-me"
ln -s /elsewhere/sh_herdr "$dev/sh_herdr"
"$installer" > "$test_root/conflict.out" 2>&1
assert_eq "conflicts exit one" 1 "$?"
assert_contains "real directory is refused" "sh_marimo: $dev/sh_marimo exists and is not a symlink" "$test_root/conflict.out"
assert_contains "foreign symlink is refused" "sh_herdr: $dev/sh_herdr already points to /elsewhere/sh_herdr" "$test_root/conflict.out"
assert_contains "summary describes partial processing" "2 problem(s); the other apps were processed as shown above." "$test_root/conflict.out"
assert_eq "real directory is preserved" "yes" "$([[ -f $dev/sh_marimo/keep-me ]] && echo yes)"
assert_link "foreign symlink is preserved" "$dev/sh_herdr" "/elsewhere/sh_herdr"
assert_link "unaffected app still installs" "$dev/sh_supacode" "$repo_root/sh_supacode"

# Usage and input errors.
"$installer" --bogus-flag > "$test_root/flag.out" 2>&1
assert_eq "unknown argument is a usage error" 2 "$?"
"$installer" --help > "$test_root/help.out" 2>&1
assert_eq "help exits zero" 0 "$?"
assert_contains "help lists the default apps" "sh_agentic-engineering sh_herdr sh_marimo sh_supacode" "$test_root/help.out"
assert_contains "help names the sandbox directory" "$dev" "$test_root/help.out"
rm -rf "$HOME/ondemand"
mkdir -p "$HOME/ondemand"; touch "$HOME/ondemand/dev"
"$installer" > "$test_root/notdir.out" 2>&1
assert_eq "file at the sandbox path exits one" 1 "$?"
assert_contains "file at the sandbox path is explained" "$dev exists but is not a directory" "$test_root/notdir.out"

if (( failures == 0 )); then printf 'All installer tests passed.\n'; else printf '%d installer test(s) failed.\n' "$failures" >&2; exit 1; fi
