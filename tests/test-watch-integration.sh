#!/usr/bin/env bash
# The whole watcher with real inotify. No network: gdrive-sync is a fake that
# hands --list-paths to the real script and records the --only= runs.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v inotifywait >/dev/null || {
  printf '  skip %s (inotifywait missing)\n' "$(basename "$0")"
  exit 0
}

make_sandbox
WATCH_PID=""
cleanup() { [[ -n "$WATCH_PID" ]] && kill "$WATCH_PID" 2>/dev/null; cleanup_sandbox; }
trap cleanup EXIT

CALLS="$SANDBOX/calls.log"
: > "$CALLS"

cat > "$SANDBOX/fake-sync" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--list-paths" ]]; then exec "$GDRIVE_SYNC" --list-paths; fi
printf '%s\n' "\$1" >> "$CALLS"
exit "\$(cat "$SANDBOX/rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$SANDBOX/fake-sync"

export GDRIVE_SYNC_BIN="$SANDBOX/fake-sync"
export GDRIVE_DEBOUNCE_SEC=1
export GDRIVE_RETRY_SEC=2

write_folders <<'EOF'
zz Documents
zz Rusty Armour
zz-missing
EOF
mkdir -p "$GDRIVE_LOCAL/zz Documents" "$GDRIVE_LOCAL/zz Rusty Armour"

WLOG="$SANDBOX/watch.log"
"$GDRIVE_WATCH" > "$WLOG" 2>&1 &
WATCH_PID=$!

if wait_for 10 grep -q 'Watches established' "$WLOG"; then
  pass "the watcher started"
else
  fail "the watcher started" "log: $(cat "$WLOG")"
fi

assert_contains "folder table logged" "$(cat "$WLOG")" "--only=zz Rusty Armour"
assert_contains "missing directory as a warning" "$(cat "$WLOG")" "directory does not exist, skipping: $GDRIVE_LOCAL/zz-missing"

# --- A local save triggers the sync -----------------------------------------
echo "content" > "$GDRIVE_LOCAL/zz Rusty Armour/note.md"
if wait_for 15 grep -qxF -- "--only=zz Rusty Armour" "$CALLS"; then
  pass "the save triggered --only= for the right folder"
else
  fail "the save triggered --only= for the right folder" "runs: $(cat "$CALLS")" "log: $(cat "$WLOG")"
fi
assert_contains "success logged" "$(cat "$WLOG")" "zz Rusty Armour: synced"

# Only the changed folder is run
assert_eq "the other folder was not run" 0 "$(grep -cxF -- '--only=zz Documents' "$CALLS")"

# --- Exclude pattern: a temporary file triggers nothing ---------------------
: > "$CALLS"
echo "junk" > "$GDRIVE_LOCAL/zz Documents/.note.md.swp"
sleep 3
assert_eq "an excluded file triggers no run" "" "$(cat "$CALLS")"

# --- A subdirectory belongs to its root folder ------------------------------
mkdir -p "$GDRIVE_LOCAL/zz Documents/2026"
echo "x" > "$GDRIVE_LOCAL/zz Documents/2026/report.md"
if wait_for 15 grep -qxF -- "--only=zz Documents" "$CALLS"; then
  pass "a change in a subdirectory triggers the root folder"
else
  fail "a change in a subdirectory triggers the root folder" "runs: $(cat "$CALLS")"
fi

# --- §3.5: saving folders.txt by rename ends the watcher with code 0 --------
printf 'zz Documents\n' > "$GDRIVE_CONF_DIR/folders.txt.new"
mv "$GDRIVE_CONF_DIR/folders.txt.new" "$GDRIVE_CONF_DIR/folders.txt"
if wait_for 15 sh -c "! kill -0 $WATCH_PID 2>/dev/null"; then
  wait "$WATCH_PID"; wrc=$?
  assert_rc "renaming folders.txt ends with code 0" 0 "$wrc"
else
  fail "renaming folders.txt ends with code 0" "the watcher did not exit"
  kill "$WATCH_PID" 2>/dev/null
fi
WATCH_PID=""
assert_contains "restart reason logged" "$(cat "$WLOG")" "changed"

# No inotifywait was left hanging
assert_eq "inotifywait cleaned up" 0 "$(pgrep -fc "inotifywait.*$GDRIVE_LOCAL" || true)"

# --- R10: an empty folder list stops startup --------------------------------
printf '# empty\n' > "$GDRIVE_CONF_DIR/folders.txt"
out="$("$GDRIVE_WATCH" 2>&1)"; rc=$?
assert_rc "empty folder list -> non-zero" 1 "$rc"
assert_contains "empty folder list -> reason" "$out" "--list-paths"

finish
