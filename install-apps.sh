#!/usr/bin/env bash
# Register this checkout's Open OnDemand sandbox apps for the invoking user.
#
# Open OnDemand loads a user's development ("sandbox") apps from
# ~/ondemand/dev/<app>. This script creates one symlink per app pointing into
# this checkout, so the shared `_common` form JavaScript stays reachable and
# `git pull` updates every installed app at once. It touches nothing outside
# that directory, needs no sudo, and never replaces or deletes anything.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
apps=(sh_agentic-engineering sh_herdr sh_marimo sh_supacode)
dev_dir=$HOME/ondemand/dev
problems=0

usage() {
  cat <<USAGE
Usage: install-apps.sh

Links ${apps[*]}
from this checkout into $dev_dir, your OnDemand sandbox app directory.
Safe to rerun. An existing file, directory, or symlink that points elsewhere is
never replaced; move it aside and rerun.

Exit status: 0 when every app is installed, 1 when a conflict or error was
reported, 2 for usage errors.
USAGE
}

say() { printf '%s\n' "$*"; }
problem() { printf 'install-apps: %s\n' "$*" >&2; problems=$((problems + 1)); }

# True when a symlink target (relative to the sandbox directory) and an app
# directory resolve to the same physical directory.
same_dir() {
  local target=$1 app_dir=$2 resolved_target resolved_app
  [[ $target == /* ]] || target="$dev_dir/$target"
  resolved_target=$(cd -- "$target" 2>/dev/null && pwd -P) || return 1
  resolved_app=$(cd -- "$app_dir" 2>/dev/null && pwd -P) || return 1
  [[ $resolved_target == "$resolved_app" ]]
}

install_app() {
  local app=$1 app_dir link target
  app_dir="$repo_root/$app"
  if [[ ! -f $app_dir/manifest.yml ]]; then
    problem "$app: not an OnDemand app in $repo_root (no manifest.yml)"
    return
  fi
  link="$dev_dir/$app"
  if [[ -L $link ]]; then
    target=$(readlink -- "$link")
    if ! same_dir "$target" "$app_dir"; then
      problem "$app: $link already points to $target; remove or move that symlink, then rerun"
      return
    fi
    say "$app: already installed ($link -> $target)"
  elif [[ -e $link ]]; then
    problem "$app: $link exists and is not a symlink; move it aside before installing this app"
    return
  else
    ln -s -- "$app_dir" "$link"
    say "$app: linked $link -> $app_dir"
  fi
  if [[ -f $app_dir/template/script.sh.erb && ! -x $app_dir/template/script.sh.erb ]]; then
    problem "$app: template/script.sh.erb is not executable; OnDemand runs it directly (chmod 755 it)"
  fi
}

case ${1:-} in
  '') ;;
  -h|--help) usage; exit 0 ;;
  *) printf 'install-apps: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac

if [[ -e $dev_dir && ! -d $dev_dir ]]; then
  problem "$dev_dir exists but is not a directory"
  exit 1
fi
[[ -d $repo_root/_common ]] || problem "_common is missing from $repo_root; the apps' file pickers need it"
if [[ ! -d $dev_dir ]]; then
  mkdir -p -- "$dev_dir"
  say "created $dev_dir"
fi

for app in "${apps[@]}"; do
  install_app "$app"
done

if (( problems > 0 )); then
  printf 'install-apps: %d problem(s); the other apps were processed as shown above.\n' "$problems" >&2
  exit 1
fi
cat <<DONE

Installed apps appear in OnDemand under Develop -> My Sandbox Apps
(https://ondemand.sherlock.stanford.edu). If the Develop menu is missing, app
development has not been enabled for your account: that is a site-side step the
Sherlock team performs (Open OnDemand "Enabling App Development"), not something
this script can do. Update the apps later with git pull in $repo_root.
DONE
