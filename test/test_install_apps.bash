#!/usr/bin/env bash
# Exercise install-apps.sh against a throwaway sandbox directory. The real
# checkout is the (read-only) source of apps.
set -u

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$test_dir/.." && pwd -P)
installer="$repo_root/install-apps.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/sh-ood-install.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
export HOME="$test_root/home"
mkdir -p "$HOME"
dev="$test_root/sandbox/dev"
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

# A dry run changes nothing.
"$installer" --dev-dir "$dev" --dry-run > "$test_root/dry.out" 2>&1
assert_eq "dry run exits zero" 0 "$?"
assert_absent "dry run creates no sandbox directory" "$dev"
assert_contains "dry run describes the links" "would sh_marimo: linked $dev/sh_marimo -> $repo_root/sh_marimo" "$test_root/dry.out"

# A fresh install links the default apps.
"$installer" --dev-dir "$dev" > "$test_root/fresh.out" 2>&1
assert_eq "fresh install exits zero" 0 "$?"
for app in "${default_apps[@]}"; do
  assert_link "fresh install links $app" "$dev/$app" "$repo_root/$app"
done
assert_absent "fresh install leaves system-provided apps alone" "$dev/sh_jupyterlab"
assert_contains "fresh install explains the Develop menu" "Develop -> My Sandbox Apps" "$test_root/fresh.out"
assert_contains "fresh install names the site-side prerequisite" "Enabling App Development" "$test_root/fresh.out"
assert_eq "linked app resolves its manifest" "yes" "$([[ -f $dev/sh_agentic-engineering/manifest.yml ]] && echo yes)"
assert_eq "linked app reaches the shared form JavaScript" "yes" "$([[ -f $dev/sh_agentic-engineering/form.js ]] && echo yes)"

# Repeating the install is a no-op.
"$installer" --dev-dir "$dev" > "$test_root/repeat.out" 2>&1
assert_eq "repeat install exits zero" 0 "$?"
assert_contains "repeat install reports already installed" "sh_herdr: already installed" "$test_root/repeat.out"
if grep -q 'linked' "$test_root/repeat.out"; then fail "repeat install links nothing"; else pass "repeat install links nothing"; fi

# An equivalent symlink spelled differently still counts as installed.
rm "$dev/sh_marimo"; ln -s "$repo_root/sh_marimo/" "$dev/sh_marimo"
"$installer" --dev-dir "$dev" --app sh_marimo > "$test_root/equiv.out" 2>&1
assert_eq "equivalent symlink is accepted" 0 "$?"
assert_contains "equivalent symlink reports already installed" "sh_marimo: already installed" "$test_root/equiv.out"

# A real directory or a foreign symlink is a conflict; other apps still install.
rm "$dev/sh_marimo" "$dev/sh_herdr" "$dev/sh_supacode"
mkdir "$dev/sh_marimo"; touch "$dev/sh_marimo/keep-me"
ln -s /elsewhere/sh_herdr "$dev/sh_herdr"
"$installer" --dev-dir "$dev" > "$test_root/conflict.out" 2>&1
assert_eq "conflicts exit one" 1 "$?"
assert_contains "real directory is refused" "sh_marimo: $dev/sh_marimo exists and is not a symlink" "$test_root/conflict.out"
assert_contains "foreign symlink is refused without --force" "sh_herdr: $dev/sh_herdr already points to /elsewhere/sh_herdr" "$test_root/conflict.out"
assert_eq "real directory is preserved" "yes" "$([[ -f $dev/sh_marimo/keep-me ]] && echo yes)"
assert_link "foreign symlink is preserved" "$dev/sh_herdr" "/elsewhere/sh_herdr"
assert_link "unaffected app still installs" "$dev/sh_supacode" "$repo_root/sh_supacode"

# --force replaces only symlinks.
"$installer" --dev-dir "$dev" --force > "$test_root/force.out" 2>&1
assert_eq "forced install still reports the directory conflict" 1 "$?"
assert_link "--force replaces the foreign symlink" "$dev/sh_herdr" "$repo_root/sh_herdr"
assert_eq "--force never removes a real directory" "yes" "$([[ -f $dev/sh_marimo/keep-me ]] && echo yes)"

# --remove deletes only this checkout's links.
ln -s /elsewhere/sh_supacode "$dev/sh_supacode-foreign"
"$installer" --dev-dir "$dev" --remove --app sh_herdr --app sh_marimo --app sh_supacode-foreign --app sh_absent > "$test_root/remove.out" 2>&1
assert_eq "remove exits zero" 0 "$?"
assert_absent "remove deletes this checkout's link" "$dev/sh_herdr"
assert_eq "remove leaves real directories" "yes" "$([[ -d $dev/sh_marimo ]] && echo yes)"
assert_link "remove leaves foreign symlinks" "$dev/sh_supacode-foreign" "/elsewhere/sh_supacode"
assert_contains "remove reports uninstalled apps" "sh_absent: not installed" "$test_root/remove.out"
assert_link "remove leaves unselected apps installed" "$dev/sh_agentic-engineering" "$repo_root/sh_agentic-engineering"

# --all installs every app directory with a manifest.
all_dev="$test_root/all"
"$installer" --dev-dir "$all_dev" --all > "$test_root/all.out" 2>&1
assert_eq "--all exits zero" 0 "$?"
expected=$(find "$repo_root" -maxdepth 2 -name manifest.yml -path "$repo_root/sh_*" | wc -l | tr -d ' ')
actual=$(find "$all_dev" -maxdepth 1 -type l | wc -l | tr -d ' ')
assert_eq "--all links every manifest-bearing app" "$expected" "$actual"

# Usage and input errors.
"$installer" --dev-dir "$dev" --app bogus > "$test_root/bogus.out" 2>&1
assert_eq "unknown app exits one" 1 "$?"
assert_contains "unknown app is explained" "bogus: not an OnDemand app" "$test_root/bogus.out"
"$installer" --dev-dir "$dev" --app '../etc' > "$test_root/traversal.out" 2>&1
assert_eq "path-like app name is a usage error" 2 "$?"
"$installer" --bogus-flag > "$test_root/flag.out" 2>&1
assert_eq "unknown flag is a usage error" 2 "$?"
"$installer" --dev-dir relative/dir > "$test_root/relative.out" 2>&1
assert_eq "relative sandbox directory is a usage error" 2 "$?"
"$installer" --help > "$test_root/help.out" 2>&1
assert_eq "help exits zero" 0 "$?"
assert_contains "help lists the default apps" "sh_agentic-engineering sh_herdr sh_marimo sh_supacode" "$test_root/help.out"
touch "$test_root/not-a-dir"
"$installer" --dev-dir "$test_root/not-a-dir" > "$test_root/notdir.out" 2>&1
assert_eq "file at the sandbox path exits one" 1 "$?"

# The default sandbox directory lives under the invoking user's home.
"$installer" --dry-run > "$test_root/default.out" 2>&1
assert_eq "default dry run exits zero" 0 "$?"
assert_contains "default sandbox directory is ~/ondemand/dev" "would created $HOME/ondemand/dev" "$test_root/default.out"

if (( failures == 0 )); then printf 'All installer tests passed.\n'; else printf '%d installer test(s) failed.\n' "$failures" >&2; exit 1; fi
