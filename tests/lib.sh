#!/usr/bin/env bash
# Shared test helpers. No dependency on the network or on Drive.
#
# SC2034: everything defined here is consumed by the test files that source
# this one, which shellcheck cannot see from inside this file.
# shellcheck disable=SC2034
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GDRIVE_SYNC="$REPO_ROOT/gdrive-sync"
GDRIVE_WATCH="$REPO_ROOT/gdrive-watch"

TESTS_RUN=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '  ok   %s\n' "$1"; }

fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  FAIL %s\n' "$1"
  shift
  local line
  for line in "$@"; do printf '       %s\n' "$line"; done
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$name"
  else
    fail "$name" "expected: [$expected]" "got:      [$actual]"
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "not found:  [$needle]" "in output:  [$haystack]"
  fi
}

# Presence of a path, symlinks included — a broken symlink is still something
# that is there.
assert_path() {
  local name="$1" path="$2"
  if [[ -e "$path" || -L "$path" ]]; then pass "$name"; else fail "$name" "missing: $path"; fi
}

assert_no_path() {
  local name="$1" path="$2"
  if [[ -e "$path" || -L "$path" ]]; then fail "$name" "still there: $path"; else pass "$name"; fi
}

assert_rc() {
  local name="$1" expected="$2" actual="$3"
  assert_eq "$name" "$expected" "$actual"
}

finish() {
  printf '%s: %d tests, %d failed\n' "$(basename "$0")" "$TESTS_RUN" "$TESTS_FAILED"
  (( TESTS_FAILED == 0 ))
}

# --- Sandbox ----------------------------------------------------------------
# gdrive-sync takes its whole environment from variables, so a test run touches
# neither the real Drive directory nor the real state directory.
make_sandbox() {
  SANDBOX="$(mktemp -d)"
  export GDRIVE_CONF_DIR="$SANDBOX/conf"
  export GDRIVE_STATE_DIR="$SANDBOX/state"
  export GDRIVE_LOCAL="$SANDBOX/local"
  export RCLONE_CALLS="$SANDBOX/rclone-calls.log"
  export PATH="$REPO_ROOT/tests/fake-bin:$PATH"
  mkdir -p "$GDRIVE_CONF_DIR" "$GDRIVE_STATE_DIR" "$GDRIVE_LOCAL"
  : > "$GDRIVE_CONF_DIR/filter.txt"
  : > "$RCLONE_CALLS"
}

# The profile layout, for the tests that are about profiles rather than about
# syncing. It sets the two roots and leaves GDRIVE_CONF_DIR and
# GDRIVE_STATE_DIR unset, which is what makes the profile the thing being
# resolved — make_sandbox pins both directly and so never resolves one.
make_profile_sandbox() {
  SANDBOX="$(mktemp -d)"
  unset GDRIVE_CONF_DIR GDRIVE_STATE_DIR GDRIVE_LOCAL GDRIVE_PROFILE
  export GDRIVE_CONF_ROOT="$SANDBOX/config"
  export GDRIVE_STATE_ROOT="$SANDBOX/state"
  # The defaults being tested are relative to HOME, so HOME has to be inside
  # the sandbox. cleanup_sandbox puts the real one back.
  SANDBOX_OLD_HOME="$HOME"
  export HOME="$SANDBOX/home"
  export RCLONE_CALLS="$SANDBOX/rclone-calls.log"
  export PATH="$REPO_ROOT/tests/fake-bin:$PATH"
  mkdir -p "$GDRIVE_CONF_ROOT" "$GDRIVE_STATE_ROOT" "$HOME"
  : > "$RCLONE_CALLS"
}

# One profile: its directory, an empty filter, and a config.env naming its own
# local root. Takes the profile name and, optionally, the local root.
make_profile() {
  local name="$1" local_root="${2:-$SANDBOX/local/$1}"
  local dir="$GDRIVE_CONF_ROOT/$name"
  mkdir -p "$dir" "$local_root"
  : > "$dir/filter.txt"
  printf 'Documents\n' > "$dir/folders.txt"
  {
    printf 'GDRIVE_REMOTE=Remote_%s\n' "$name"
    printf 'GDRIVE_LOCAL=%s\n' "$local_root"
  } > "$dir/config.env"
}

cleanup_sandbox() {
  [[ -n "${SANDBOX_OLD_HOME:-}" ]] && { export HOME="$SANDBOX_OLD_HOME"; SANDBOX_OLD_HOME=""; }
  [[ -n "${SANDBOX:-}" ]] && rm -rf "$SANDBOX"
  return 0
}

write_folders() { cat > "$GDRIVE_CONF_DIR/folders.txt"; }

# Name-hostile fixtures (R12): spaces, non-ASCII, brackets, a slash. The same
# set runs through every test file.
HOSTILE_NAMES=(
  'Rusty Armour'
  'Naïve Café'
  'Photos [2026]'
  'Projects/2026'
)

# Wait at most <seconds> for <command> to succeed.
wait_for() {
  local deadline=$(( SECONDS + $1 )); shift
  while (( SECONDS < deadline )); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  return 1
}
