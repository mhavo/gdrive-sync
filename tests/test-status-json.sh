#!/usr/bin/env bash
# status.json: the machine-readable record of a run, read by the Omarchy widget.
# Design: docs/superpowers/specs/2026-09-15-omarchy-widget-design.md
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_sandbox
trap cleanup_sandbox EXIT

STATUS="$GDRIVE_STATE_DIR/status.json"

# The timestamps the widget parses. Same shape as marker_write's pinned= field.
ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$'

assert_json() {
  local name="$1" file="$2"
  if jq -e . "$file" >/dev/null 2>&1; then pass "$name"; else fail "$name" "not valid JSON: $(cat "$file" 2>&1)"; fi
}

assert_jq() {  # name expected file filter
  local name="$1" expected="$2" file="$3" filter="$4"
  assert_eq "$name" "$expected" "$(jq -r "$filter" "$file" 2>&1)"
}

assert_iso() {
  local name="$1" value="$2"
  if [[ "$value" =~ $ISO_RE ]]; then pass "$name"; else fail "$name" "not ISO-8601 with a zone: [$value]"; fi
}

# gdrive-sync is run without GDRIVE_TRIGGER unless a test sets it, so the
# default is exercised rather than whatever the harness happens to export.
sync_run() { env -u GDRIVE_TRIGGER "$GDRIVE_SYNC" "$@"; }

# --- A complete successful run ----------------------------------------------
write_folders <<'EOF'
Documents
Rusty Armour
EOF
export RCLONE_LSJSON='[{"Name":"Documents","ID":"documents-id"},{"Name":"Rusty Armour","ID":"armour-id"}]'

out="$(sync_run 2>&1)"; rc=$?
assert_rc "a successful run exits 0" 0 "$rc"
assert_path "the run wrote status.json" "$STATUS"
assert_json "status.json is valid JSON" "$STATUS"
assert_jq "schema is 1" 1 "$STATUS" '.schema'
assert_jq "version is the tool's version" "$("$GDRIVE_SYNC" --version | awk '{print $2}')" "$STATUS" '.version'
assert_iso "run.started is ISO-8601 with a zone" "$(jq -r '.run.started' "$STATUS")"
assert_iso "run.finished is ISO-8601 with a zone" "$(jq -r '.run.finished' "$STATUS")"
assert_jq "run.exit is the exit code" 0 "$STATUS" '.run.exit'
assert_jq "run.trigger defaults to manual" manual "$STATUS" '.run.trigger'
assert_jq "run.dryRun is false" false "$STATUS" '.run.dryRun'
# Logging is the journal's job now, so the record names no file. The key must be
# absent rather than null: a reader that tests for it must not find one.
assert_jq "there is no log field" false "$STATUS" 'has("log")'

# The first run initialises with --resync, which is its own result: it is not a
# failure, and the widget must not render it as an ordinary sync either.
assert_jq "both folders are recorded" 2 "$STATUS" '.folders | length'
assert_jq "a folder is named as it is written in folders.txt" "Documents" "$STATUS" '.folders[0].name'
assert_jq "a name with a space survives" "Rusty Armour" "$STATUS" '.folders[1].name'
assert_jq "the first run of a folder is initialising" initialising "$STATUS" '.folders[0].result'
assert_iso "a folder result carries its own timestamp" "$(jq -r '.folders[0].at' "$STATUS")"
assert_jq "a successful folder has no reason" "null" "$STATUS" '.folders[0].reason'

# --- The second run is an ordinary sync -------------------------------------
sync_run >/dev/null 2>&1
assert_jq "an already initialised folder is ok" ok "$STATUS" '.folders[0].result'
assert_jq "every result is in the documented set" true "$STATUS" \
  '[.folders[].result] | all(. == "ok" or . == "error" or . == "skipped" or . == "initialising" or . == "running")'

# --- trigger comes from the environment -------------------------------------
GDRIVE_TRIGGER=timer "$GDRIVE_SYNC" >/dev/null 2>&1
assert_jq "trigger is taken from GDRIVE_TRIGGER" timer "$STATUS" '.run.trigger'
GDRIVE_TRIGGER=watch "$GDRIVE_SYNC" >/dev/null 2>&1
assert_jq "the watcher's trigger is recorded" watch "$STATUS" '.run.trigger'

# --- A failing folder: the reason is the text the CLI already prints ---------
write_folders <<'EOF'
Documents
EOF
export RCLONE_LSF_RC=1
out="$(sync_run 2>&1)"; rc=$?
assert_rc "a failing folder exits 1" 1 "$rc"
assert_jq "a failing folder is an error" error "$STATUS" '.folders[0].result'
reason="$(jq -r '.folders[0].reason' "$STATUS")"
assert_contains "the reason repeats the logged text" "$out" "$reason"
assert_contains "the reason names the failure" "$reason" "does not resolve in Drive"
assert_jq "run.exit records the failure" 1 "$STATUS" '.run.exit'
unset RCLONE_LSF_RC

# --- A skipped folder is not an error ---------------------------------------
write_folders <<'EOF'
Documents
EOF
mkdir -p "$GDRIVE_LOCAL/Documents"
printf 'local only\n' > "$GDRIVE_LOCAL/Documents/keep.txt"
export RCLONE_LSF_OUTPUT=""
out="$(sync_run 2>&1)"
assert_jq "an empty remote with a full local folder is skipped" skipped "$STATUS" '.folders[0].result'
assert_contains "the skip reason repeats the logged text" "$out" "$(jq -r '.folders[0].reason' "$STATUS")"
unset RCLONE_LSF_OUTPUT

# --- A dry run writes nothing -----------------------------------------------
# Previewing work must not overwrite the record of real work: the widget would
# otherwise show a preview as the last run.
before="$(cat "$STATUS")"
out="$(sync_run -n 2>&1)"; rc=$?
assert_rc "a dry run succeeds" 0 "$rc"
assert_eq "a dry run leaves status.json untouched" "$before" "$(cat "$STATUS")"

rm -f "$STATUS"
sync_run -n >/dev/null 2>&1
assert_no_path "a dry run creates no status.json" "$STATUS"

# --- Queries write nothing either -------------------------------------------
sync_run --status >/dev/null 2>&1
assert_no_path "--status creates no status.json" "$STATUS"
sync_run --list-paths >/dev/null 2>&1
assert_no_path "--list-paths creates no status.json" "$STATUS"

# --- Exit 75: the lock was held ---------------------------------------------
# Not a failure. The file records it so the widget can tell an overlapping run
# apart from a broken one; there are no folder results because none were run.
exec 9>"$GDRIVE_STATE_DIR/lock"
flock -x 9
out="$(sync_run 2>&1)"; rc=$?
flock -u 9
exec 9>&-
assert_rc "lock contention still exits 75" 75 "$rc"
assert_path "exit 75 writes status.json" "$STATUS"
assert_json "the exit 75 file is valid JSON" "$STATUS"
assert_jq "exit 75 is recorded as such" 75 "$STATUS" '.run.exit'
assert_jq "exit 75 records no folders" 0 "$STATUS" '.folders | length'
assert_iso "exit 75 still has a finished time" "$(jq -r '.run.finished' "$STATUS")"

# --- A run in progress ------------------------------------------------------
# finished stays null while the run is going, so the widget can show "syncing"
# instead of only the outcome. The slow bisync double gives the test a window.
write_folders <<'EOF'
Documents
Rusty Armour
EOF
rm -f "$STATUS"
export RCLONE_BISYNC_SLEEP=3
sync_run >/dev/null 2>&1 &
sync_pid=$!
if wait_for 10 test -s "$STATUS"; then
  pass "status.json appears while the run is still going"
else
  fail "status.json appears while the run is still going"
fi
assert_json "an in-progress file is valid JSON" "$STATUS"
assert_jq "run.finished is null while in progress" null "$STATUS" '.run.finished'
assert_jq "run.exit is null while in progress" null "$STATUS" '.run.exit'
assert_iso "run.started is set while in progress" "$(jq -r '.run.started' "$STATUS")"
assert_jq "a folder not yet finished is running" true "$STATUS" \
  '[.folders[].result] | any(. == "running")'

# --- Atomicity --------------------------------------------------------------
# The reader polls as fast as it can for the rest of the run. A temp file in
# another directory, or a write straight into status.json, shows up here as a
# parse failure.
bad=0
reads=0
while kill -0 "$sync_pid" 2>/dev/null; do
  jq -e . "$STATUS" >/dev/null 2>&1 || bad=$((bad + 1))
  reads=$((reads + 1))
done
wait "$sync_pid"
assert_eq "the reader got a whole file every time ($reads reads)" 0 "$bad"
unset RCLONE_BISYNC_SLEEP

assert_jq "the finished run has a finished time" true "$STATUS" '.run.finished != null'
assert_eq "no temporary file is left behind" "" \
  "$(find "$GDRIVE_STATE_DIR" -maxdepth 1 -name 'status.json.*' -print)"

finish
