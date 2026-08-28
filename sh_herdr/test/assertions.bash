#!/usr/bin/env bash

TEST_FAILURES=0

assert_success() {
  local description=$1
  shift
  if "$@"; then
    printf 'PASS: %s\n' "$description"
  else
    printf 'FAIL: %s\n' "$description" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
  fi
}

assert_failure() {
  local description=$1
  shift
  if "$@"; then
    printf 'FAIL: %s\n' "$description" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
  else
    printf 'PASS: %s\n' "$description"
  fi
}

assert_eq() {
  local description=$1
  local expected=$2
  local actual=$3
  if [[ $expected == "$actual" ]]; then
    printf 'PASS: %s\n' "$description"
  else
    printf 'FAIL: %s (expected %q, got %q)\n' "$description" "$expected" "$actual" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
  fi
}

finish_tests() {
  if (( TEST_FAILURES == 0 )); then
    printf 'All tests passed.\n'
    return 0
  fi

  printf '%d test(s) failed.\n' "$TEST_FAILURES" >&2
  return 1
}
