#!/usr/bin/env bash

validate_job_id() {
  [[ ${1:-} =~ ^[0-9]+$ ]]
}

validate_session_name() {
  local value=${1:-}
  [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] &&
    [[ $value != '.' && $value != '..' ]]
}

state_root() {
  printf '%s\n' "${SHERLOCK_HERDR_STATE_ROOT:-$HOME/.local/state/sherlock-herdr}"
}

ensure_state_root() {
  local root
  root=$(state_root) || return 1

  umask 077
  mkdir -p "$root/jobs" "$root/sessions" || return 1
  chmod 700 "$root" "$root/jobs" "$root/sessions"
}

job_record_path() {
  local job_id=${1:-}
  validate_job_id "$job_id" || return 1
  printf '%s/jobs/%s\n' "$(state_root)" "$job_id"
}

session_lock_path() {
  local session=${1:-}
  validate_session_name "$session" || return 1
  printf '%s/sessions/%s\n' "$(state_root)" "$session"
}

expected_runtime_dir() {
  local job_id=${1:-}
  validate_job_id "$job_id" || return 1
  printf '/tmp/sherlock-herdr-%s-%s\n' "$UID" "$job_id"
}

expected_socket_path() {
  local job_id=${1:-}
  local runtime_dir
  runtime_dir=$(expected_runtime_dir "$job_id") || return 1
  printf '%s/herdr.sock\n' "$runtime_dir"
}

write_job_record() {
  local job_id=${1:-}
  local session=${2:-}
  local socket=${3:-}
  local host=${4:-}
  local root record temporary expected_socket

  validate_job_id "$job_id" || return 1
  validate_session_name "$session" || return 1
  expected_socket=$(expected_socket_path "$job_id") || return 1
  [[ $socket == "$expected_socket" ]] || return 1
  [[ $socket != *$'\t'* && $socket != *$'\n'* ]] || return 1
  [[ $host != *$'\t'* && $host != *$'\n'* ]] || return 1
  ensure_state_root || return 1
  root=$(state_root) || return 1
  record=$(job_record_path "$job_id") || return 1
  temporary=$(mktemp "$root/jobs/.${job_id}.XXXXXX") || return 1

  if ! printf '%s\t%s\t%s\n' "$session" "$socket" "$host" > "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi

  chmod 600 "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  mv -f "$temporary" "$record"
}

read_job_record() {
  local record
  record=$(job_record_path "${1:-}") || return 1
  [[ -f $record ]] || return 1
  IFS= read -r _ < "$record" || [[ -s $record ]] || return 1
  cat "$record"
}

acquire_session_lock() {
  local session=${1:-}
  local job_id=${2:-}
  local root lock owner active_job_ids active_job_id owner_active stale attempt

  validate_session_name "$session" || return 1
  validate_job_id "$job_id" || return 1
  ensure_state_root || return 1
  root=$(state_root) || return 1
  lock=$(session_lock_path "$session") || return 1

  for attempt in 1 2; do
    if mkdir "$lock" 2>/dev/null; then
      if printf '%s\n' "$job_id" > "$lock/owner_job"; then
        chmod 600 "$lock/owner_job"
        return $?
      fi
      rm -rf -- "$lock"
      return 1
    fi

    (( attempt == 1 )) || return 1
    [[ -d $lock && -f $lock/owner_job ]] || return 1
    owner=$(< "$lock/owner_job")
    validate_job_id "$owner" || return 1
    active_job_ids=$(squeue -h -u "${USER:-$(id -un)}" -o '%A' 2>/dev/null) || return 1
    owner_active=0
    while IFS= read -r active_job_id; do
      if [[ $active_job_id == "$owner" ]]; then
        owner_active=1
        break
      fi
    done <<< "$active_job_ids"
    (( owner_active == 0 )) || return 1

    stale="$root/sessions/.stale-${session}-${job_id}-${BASHPID:-$$}"
    [[ ! -e $stale && ! -L $stale ]] || return 1
    mv "$lock" "$stale" || return 1
    rm -rf -- "$stale"
  done

  return 1
}

release_job_state() {
  local session=${1:-}
  local job_id=${2:-}
  local root lock owner released_lock record released_record

  validate_session_name "$session" || return 1
  validate_job_id "$job_id" || return 1
  root=$(state_root) || return 1
  lock=$(session_lock_path "$session") || return 1
  record=$(job_record_path "$job_id") || return 1

  if [[ -e $lock ]]; then
    [[ -d $lock && -f $lock/owner_job ]] || return 0
    owner=$(< "$lock/owner_job")
    [[ $owner == "$job_id" ]] || return 0

    released_lock="$root/sessions/.released-${session}-${job_id}-${BASHPID:-$$}"
    [[ ! -e $released_lock && ! -L $released_lock ]] || return 0
    mv "$lock" "$released_lock" || return 0
    rm -rf -- "$released_lock"
  fi

  if [[ -e $record ]]; then
    released_record="$root/jobs/.released-${job_id}-${BASHPID:-$$}"
    [[ ! -e $released_record && ! -L $released_record ]] || return 0
    mv "$record" "$released_record" || return 0
    rm -f -- "$released_record"
  fi
}

remove_runtime_dir() {
  local job_id=${1:-}
  local path=${2:-}
  local expected

  expected=$(expected_runtime_dir "$job_id") || return 1
  [[ $path == "$expected" ]] || return 1
  rm -rf -- "$path"
}
