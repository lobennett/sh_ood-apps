#!/usr/bin/env bash
# Register this checkout's Open OnDemand sandbox apps for the invoking user.
#
# Open OnDemand loads a user's development ("sandbox") apps from
# ~/ondemand/dev/<app>. This script creates one symlink per app pointing into
# this checkout, so the shared `_common` form JavaScript stays reachable and
# `git pull` updates every installed app at once. It touches nothing outside
# that directory, needs no sudo, and never deletes a real file or directory.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
default_apps=(sh_agentic-engineering sh_herdr sh_marimo sh_supacode)
dev_dir=${OOD_DEV_DIR:-$HOME/ondemand/dev}
apps=()
mode=install
force=0
dry_run=0
problems=0

usage() {
  cat <<USAGE
Usage: install-apps.sh [--app NAME]... [--all] [--dev-dir DIR] [--force] [--remove] [--dry-run]

Links this checkout's OnDemand apps into your sandbox app directory.

  --app NAME     Install only this app; repeatable. Default: ${default_apps[*]}
  --all          Install every sh_* app in this checkout
  --dev-dir DIR  Sandbox app directory (default: \$HOME/ondemand/dev, or \$OOD_DEV_DIR)
  --force        Replace a symlink that points elsewhere; a real file or directory is never removed
  --remove       Remove the symlinks that point into this checkout instead of creating them
  --dry-run      Report what would change without changing anything
  -h, --help     Show this help

Exit status: 0 when every requested app is in the requested state, 1 when a
conflict or error was reported, 2 for usage errors.
USAGE
}

say() { printf '%s\n' "$*"; }
problem() { printf 'install-apps: %s\n' "$*" >&2; problems=$((problems + 1)); }
usage_error() { printf 'install-apps: %s\n' "$*" >&2; usage >&2; exit 2; }

# Run (or, with --dry-run, only describe) one change.
change() {
  local description=$1
  shift
  if (( dry_run )); then
    say "would $description"
  else
    "$@"
    say "$description"
  fi
}

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
  if [[ ! -d $app_dir || ! -f $app_dir/manifest.yml ]]; then
    problem "$app: not an OnDemand app in $repo_root (no manifest.yml)"
    return
  fi
  link="$dev_dir/$app"
  if [[ -L $link ]]; then
    target=$(readlink -- "$link")
    if same_dir "$target" "$app_dir"; then
      say "$app: already installed ($link -> $target)"
    elif (( force )); then
      change "$app: replaced $link (was -> $target) with -> $app_dir" relink "$app_dir" "$link"
    else
      problem "$app: $link already points to $target; rerun with --force to replace that symlink"
      return
    fi
  elif [[ -e $link ]]; then
    problem "$app: $link exists and is not a symlink; move it aside before installing this app"
    return
  else
    change "$app: linked $link -> $app_dir" ln -s -- "$app_dir" "$link"
  fi
  if [[ -f $app_dir/template/script.sh.erb && ! -x $app_dir/template/script.sh.erb ]]; then
    problem "$app: template/script.sh.erb is not executable; OnDemand runs it directly (chmod 755 it)"
  fi
}

relink() {
  rm -f -- "$2"
  ln -s -- "$1" "$2"
}

remove_app() {
  local app=$1 link target
  link="$dev_dir/$app"
  if [[ -L $link ]]; then
    target=$(readlink -- "$link")
    if same_dir "$target" "$repo_root/$app"; then
      change "$app: removed $link" rm -f -- "$link"
    else
      say "$app: left $link alone; it points to $target, not into this checkout"
    fi
  elif [[ -e $link ]]; then
    say "$app: left $link alone; it is not a symlink"
  else
    say "$app: not installed"
  fi
}

while (( $# > 0 )); do
  case $1 in
    --app)
      [[ -n ${2:-} ]] || usage_error "--app needs a name"
      apps+=("$2")
      shift 2
      ;;
    --all)
      for dir in "$repo_root"/sh_*/; do
        [[ -f $dir/manifest.yml ]] || continue
        dir=${dir%/}
        apps+=("${dir##*/}")
      done
      shift
      ;;
    --dev-dir)
      [[ -n ${2:-} ]] || usage_error "--dev-dir needs a directory"
      dev_dir=$2
      shift 2
      ;;
    --force) force=1; shift ;;
    --remove) mode=remove; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown option: $1" ;;
  esac
done
if (( ${#apps[@]} == 0 )); then
  apps=("${default_apps[@]}")
fi
case $dev_dir in
  /*) ;;
  *) usage_error "--dev-dir must be an absolute path" ;;
esac

if [[ -e $dev_dir && ! -d $dev_dir ]]; then
  problem "$dev_dir exists but is not a directory"
  exit 1
fi
if [[ $mode == install ]]; then
  [[ -d $repo_root/_common ]] || problem "_common is missing from $repo_root; the apps' file pickers need it"
  if [[ ! -d $dev_dir ]]; then
    change "created $dev_dir" mkdir -p -- "$dev_dir"
  fi
fi

for app in "${apps[@]}"; do
  case $app in
    */*|.*|'') usage_error "invalid app name: $app" ;;
  esac
  if [[ $mode == install ]]; then
    install_app "$app"
  else
    remove_app "$app"
  fi
done

if (( problems > 0 )); then
  printf 'install-apps: %d problem(s); nothing else was changed.\n' "$problems" >&2
  exit 1
fi
if [[ $mode == install ]] && (( ! dry_run )); then
  cat <<DONE

Installed apps appear in OnDemand under Develop -> My Sandbox Apps
(https://ondemand.sherlock.stanford.edu). If the Develop menu is missing, app
development has not been enabled for your account: that is a site-side step the
Sherlock team performs (Open OnDemand "Enabling App Development"), not something
this script can do. Update the apps later with git pull in $repo_root.
DONE
fi
