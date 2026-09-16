#!/usr/bin/env bash
# Profiles: which account a run addresses, and the refusal to guess.
#
# The rules here are the ones whose failure mode is a deletion propagating to
# the wrong Drive, so each one is tested by what the script refuses as much as
# by what it accepts.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

run_sync() {
  "$GDRIVE_SYNC" "$@" >"$SANDBOX/out" 2>"$SANDBOX/err"
  SYNC_RC=$?
  SYNC_OUT="$(cat "$SANDBOX/out" "$SANDBOX/err")"
}

run_watch() {
  "$GDRIVE_WATCH" "$@" >"$SANDBOX/out" 2>"$SANDBOX/err"
  WATCH_RC=$?
  WATCH_OUT="$(cat "$SANDBOX/out" "$SANDBOX/err")"
}

# --- Path resolution precedence ---------------------------------------------
make_profile_sandbox
make_profile work "$SANDBOX/local/work"

run_sync --profile=work --help
assert_rc "a named profile resolves" 0 "$SYNC_RC"
assert_contains "conf dir comes from the profile" "$SYNC_OUT" \
  "$GDRIVE_CONF_ROOT/work/config.env"
assert_contains "folder list comes from the profile" "$SYNC_OUT" \
  "$GDRIVE_CONF_ROOT/work/folders.txt"
assert_contains "the profile is named in --help" "$SYNC_OUT" "Profile:     work"

# An explicit directory is the one thing that outranks the profile: it is what
# the existing test sandbox sets, and what keeps the rest of the suite running.
GDRIVE_CONF_DIR="$SANDBOX/elsewhere" GDRIVE_STATE_DIR="$SANDBOX/elsewhere-state" \
  run_sync --profile=work --help
assert_contains "GDRIVE_CONF_DIR beats the profile" "$SYNC_OUT" \
  "$SANDBOX/elsewhere/config.env"

# --- The default local root is per profile ----------------------------------
mkdir -p "$GDRIVE_CONF_ROOT/bare"
: > "$GDRIVE_CONF_ROOT/bare/filter.txt"
printf 'Documents\n' > "$GDRIVE_CONF_ROOT/bare/folders.txt"
run_sync --profile=bare --help
assert_contains "the default local root carries the profile" "$SYNC_OUT" \
  "Local root:  $HOME/GoogleDrive/bare"
cleanup_sandbox

# --- Name validation --------------------------------------------------------
# A profile name becomes a path segment and a systemd instance name, so it is
# validated rather than escaped. Hostile names belong here as rejections; Drive
# folder names, which are user data, keep their own coverage elsewhere.
make_profile_sandbox
make_profile solo "$SANDBOX/local/solo"

for bad in ".." "." "a/b" "" "with space" "${HOSTILE_NAMES[0]}" "${HOSTILE_NAMES[1]}" \
           "${HOSTILE_NAMES[2]}" "${HOSTILE_NAMES[3]}"; do
  run_sync "--profile=$bad" --help
  assert_rc "rejected profile name [$bad]" 2 "$SYNC_RC"
  assert_contains "and says why [$bad]" "$SYNC_OUT" "Invalid profile name"
done

for good in work personal a.b a-b a_b Work2; do
  mkdir -p "$GDRIVE_CONF_ROOT/$good"
  run_sync "--profile=$good" --help
  assert_rc "accepted profile name [$good]" 0 "$SYNC_RC"
  rm -rf "${GDRIVE_CONF_ROOT:?}/$good"
done
cleanup_sandbox

# --- One profile needs no flag; several do ----------------------------------
make_profile_sandbox
make_profile solo "$SANDBOX/local/solo"
run_sync --list-paths
assert_rc "a single profile is used without --profile" 0 "$SYNC_RC"
assert_contains "and it is that profile's local root" "$SYNC_OUT" \
  "$SANDBOX/local/solo/Documents"

make_profile other "$SANDBOX/local/other"
run_sync --list-paths
assert_rc "several profiles without --profile refuses" 2 "$SYNC_RC"
assert_contains "and says what to do" "$SYNC_OUT" "--profile=NAME"
assert_contains "and names the first" "$SYNC_OUT" "solo"
assert_contains "and names the second" "$SYNC_OUT" "other"

# The refusal is about which account, not about whether the tool works.
run_sync --profile=other --list-paths
assert_rc "naming one of them works" 0 "$SYNC_RC"
assert_contains "and picks its local root" "$SYNC_OUT" "$SANDBOX/local/other/Documents"
cleanup_sandbox

# --- No profile at all ------------------------------------------------------
make_profile_sandbox
run_sync --list-paths
assert_rc "no profiles at all refuses" 1 "$SYNC_RC"
assert_contains "and says how to create one" "$SYNC_OUT" "install.sh --profile="
cleanup_sandbox

# --- --list-profiles --------------------------------------------------------
make_profile_sandbox
run_sync --list-profiles
assert_rc "--list-profiles with none succeeds" 0 "$SYNC_RC"
assert_eq "and prints nothing" "" "$SYNC_OUT"

make_profile work "$SANDBOX/local/work"
make_profile personal "$SANDBOX/local/personal"
# A stray file, and a directory whose name is not a valid profile: neither is a
# profile, and both exist in a real config root sooner or later.
: > "$GDRIVE_CONF_ROOT/README"
mkdir -p "$GDRIVE_CONF_ROOT/not a profile"
run_sync --list-profiles
assert_rc "--list-profiles with several succeeds" 0 "$SYNC_RC"
assert_eq "one profile per line, nothing else" "personal
work" "$SYNC_OUT"

# It answers in exactly the situation its callers ask about: more than one
# profile, no flag. A refusal here would make the widget unable to enumerate.
assert_contains "--list-profiles does not refuse" "$SYNC_OUT" "work"
cleanup_sandbox

# --- The local root collision check -----------------------------------------
# Two profiles under one root means each one's bisync carries the other's files
# to its own Drive as deletions. The check is the reason this is refused rather
# than discovered.
make_profile_sandbox
make_profile a "$SANDBOX/shared"
make_profile b "$SANDBOX/shared"
run_sync --profile=a -n
assert_rc "an identical local root is refused" 1 "$SYNC_RC"
assert_contains "and names the other profile" "$SYNC_OUT" "profile 'b'"
assert_contains "and says what it costs" "$SYNC_OUT" "deletions"

# A preview is refused too: -n exists to show what a real run would do, and the
# real run would not happen.
run_sync --profile=b -n
assert_rc "the collision is symmetric" 1 "$SYNC_RC"

# Reporting on a configuration does not touch data, and has to keep working
# while the collision is being fixed.
run_sync --profile=a --list-paths
assert_rc "--list-paths still works" 0 "$SYNC_RC"
cleanup_sandbox

make_profile_sandbox
make_profile outer "$SANDBOX/local"
make_profile inner "$SANDBOX/local/inner"
run_sync --profile=inner -n
assert_rc "a nested local root is refused" 1 "$SYNC_RC"
assert_contains "and names the enclosing profile" "$SYNC_OUT" "profile 'outer'"
cleanup_sandbox

# A symlink must not be able to hide the nesting.
make_profile_sandbox
mkdir -p "$SANDBOX/real"
ln -s "$SANDBOX/real" "$SANDBOX/link"
make_profile a "$SANDBOX/real"
make_profile b "$SANDBOX/link"
run_sync --profile=b -n
assert_rc "a symlinked local root is refused" 1 "$SYNC_RC"
cleanup_sandbox

make_profile_sandbox
make_profile a "$SANDBOX/local/a"
make_profile b "$SANDBOX/local/b"
export RCLONE_LSJSON_ROOT='[{"Name":"Documents","ID":"ID_DOCUMENTS"}]'
run_sync --profile=a -n
assert_rc "separate local roots run" 0 "$SYNC_RC"
if [[ "$SYNC_OUT" == *"collision"* ]]; then
  fail "and say nothing about a collision" "$SYNC_OUT"
else
  pass "and say nothing about a collision"
fi
cleanup_sandbox

# --- The state directory follows the profile --------------------------------
# Two runs must not share a lock or a status.json, which is what lets profiles
# run in parallel without a global lock.
make_profile_sandbox
make_profile work "$SANDBOX/local/work"
make_profile personal "$SANDBOX/local/personal"
export RCLONE_LSJSON_ROOT='[{"Name":"Documents","ID":"ID_DOCUMENTS"}]'
run_sync --profile=work
assert_rc "a run with its own root succeeds" 0 "$SYNC_RC"
assert_path "the run writes under the profile's state directory" \
  "$GDRIVE_STATE_ROOT/work/status.json"
assert_no_path "and not under the other profile's" \
  "$GDRIVE_STATE_ROOT/personal/status.json"
cleanup_sandbox

# --- gdrive-watch resolves the same way -------------------------------------
make_profile_sandbox
make_profile work "$SANDBOX/local/work"
make_profile personal "$SANDBOX/local/personal"

unset RCLONE_LSJSON_ROOT
run_watch --help
assert_rc "the watcher refuses to guess a profile too" 2 "$WATCH_RC"
assert_contains "and lists them" "$WATCH_OUT" "personal"

run_watch --profile=work --help
assert_rc "a named profile resolves for the watcher" 0 "$WATCH_RC"
assert_contains "and it reads that profile's folder list" "$WATCH_OUT" \
  "$GDRIVE_CONF_ROOT/work/folders.txt"

run_watch --profile=.. --help
assert_rc "the watcher validates the name" 2 "$WATCH_RC"
cleanup_sandbox

finish
