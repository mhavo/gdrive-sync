#!/usr/bin/env bash
# watcher.json: the watcher's own state file, read by the Omarchy widget.
# Design: docs/superpowers/specs/2026-09-15-omarchy-widget-design.md
#
# Two files rather than one, because gdrive-sync and gdrive-watch would
# otherwise race on a shared one. This file has a single writer, so every write
# is a plain temp + mv and needs no lock.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_sandbox
WATCH_PID=""
cleanup() { [[ -n "$WATCH_PID" ]] && kill "$WATCH_PID" 2>/dev/null; cleanup_sandbox; }
trap cleanup EXIT

WATCHER="$GDRIVE_STATE_DIR/watcher.json"
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

# --- State transitions, driven through the functions themselves -------------
ARGS_LOG="$SANDBOX/args.log"
RC_FILE="$SANDBOX/rc"
echo 0 > "$RC_FILE"

cat > "$SANDBOX/fake-sync" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--list-paths" ]]; then exit 0; fi
{ printf 'trigger=%s\n' "\${GDRIVE_TRIGGER:-<unset>}"; printf 'arg=%s\n' "\$@"; } >> "$ARGS_LOG"
exit "\$(cat "$RC_FILE")"
EOF
chmod +x "$SANDBOX/fake-sync"
export GDRIVE_SYNC_BIN="$SANDBOX/fake-sync"
export GDRIVE_RETRY_SEC=30

# shellcheck source=gdrive-watch
source "$GDRIVE_WATCH"

DIRS=("$GDRIVE_LOCAL/Documents" "$GDRIVE_LOCAL/Rusty Armour")
ONLYS=("Documents" "Rusty Armour")

# watching: the watcher is up and nothing is outstanding.
DIRTY=()
watcher_set_state watching
assert_path "the watcher wrote watcher.json" "$WATCHER"
assert_json "watcher.json is valid JSON" "$WATCHER"
assert_jq "schema is 1" 1 "$WATCHER" '.schema'
assert_jq "an idle watcher is watching" watching "$WATCHER" '.state'
assert_jq "nothing is pending" 0 "$WATCHER" '.pending | length'
assert_iso "since is ISO-8601 with a zone" "$(jq -r '.since' "$WATCHER")"
assert_jq "nextRetry is null unless retrying" null "$WATCHER" '.nextRetry'

# pending: a local change is recorded but not yet synced.
mark_dirty "$GDRIVE_LOCAL/Rusty Armour/note.md"
assert_jq "a change makes the watcher pending" pending "$WATCHER" '.state'
assert_jq "the changed folder is listed" "Rusty Armour" "$WATCHER" '.pending[0]'

# A name with a slash, brackets or non-ASCII goes through jq like any other.
DIRS=("${DIRS[@]}" "$GDRIVE_LOCAL/Naïve Café" "$GDRIVE_LOCAL/Photos [2026]")
ONLYS=("${ONLYS[@]}" "Naïve Café" "Photos [2026]")
DIRTY=()
mark_dirty "$GDRIVE_LOCAL/Naïve Café/demo.flac"
mark_dirty "$GDRIVE_LOCAL/Photos [2026]/x.jpg"
assert_jq "hostile names survive as JSON strings" "Naïve Café|Photos [2026]" "$WATCHER" \
  '[.pending[]] | sort | join("|")'

# syncing and back to watching: a drain that succeeds empties the set.
echo 0 > "$RC_FILE"
DIRTY=(); DIRTY["Documents"]=1
drain >/dev/null 2>&1
assert_jq "a finished drain returns to watching" watching "$WATCHER" '.state'
assert_jq "a synced folder is no longer pending" 0 "$WATCHER" '.pending | length'
assert_jq "nextRetry is cleared again" null "$WATCHER" '.nextRetry'

# The watcher labels its own runs, so status.json says where the run came from.
assert_contains "the watcher's gdrive-sync run is triggered by the watch" \
  "$(cat "$ARGS_LOG")" "trigger=watch"

# retry: exit 75 means a run was already going, so the folder stays pending.
echo 75 > "$RC_FILE"
DIRTY=(); DIRTY["Documents"]=1
drain >/dev/null 2>&1
assert_jq "a drain that hit the lock is retrying" retry "$WATCHER" '.state'
assert_jq "the folder stays pending" "Documents" "$WATCHER" '.pending[0]'
assert_iso "a retry announces when" "$(jq -r '.nextRetry' "$WATCHER")"

# The syncing state is written while a folder is being handed to gdrive-sync.
cat > "$SANDBOX/fake-sync" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--list-paths" ]]; then exit 0; fi
cp -- "$WATCHER" "$SANDBOX/seen-during-sync.json"
exit 0
EOF
chmod +x "$SANDBOX/fake-sync"
DIRTY=(); DIRTY["Documents"]=1
drain >/dev/null 2>&1
assert_jq "the state during a run is syncing" syncing "$SANDBOX/seen-during-sync.json" '.state'

assert_eq "no temporary file is left behind" "" \
  "$(find "$GDRIVE_STATE_DIR" -maxdepth 1 -name 'watcher.json.*' -print)"

# --- stopped on a clean exit ------------------------------------------------
# A stale file must not go on claiming the watcher is alive. folders.txt
# changing is the ordinary case: the watcher exits 0 and systemd restarts it.
if ! command -v inotifywait >/dev/null; then
  printf '  skip stopped-on-exit (inotifywait missing)\n'
  finish
  exit $?
fi

rm -f "$WATCHER"
cat > "$SANDBOX/fake-sync" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--list-paths" ]]; then exec "$GDRIVE_SYNC" --list-paths; fi
exit 0
EOF
chmod +x "$SANDBOX/fake-sync"

write_folders <<'EOF'
zz Documents
EOF
mkdir -p "$GDRIVE_LOCAL/zz Documents"

WLOG="$SANDBOX/watch.log"
env GDRIVE_DEBOUNCE_SEC=1 "$GDRIVE_WATCH" > "$WLOG" 2>&1 &
WATCH_PID=$!

if wait_for 10 grep -q 'Watches established' "$WLOG"; then
  pass "the watcher started"
else
  fail "the watcher started" "log: $(cat "$WLOG")"
fi
if wait_for 10 test -s "$WATCHER"; then
  assert_jq "a running watcher says it is watching" watching "$WATCHER" '.state'
else
  fail "a running watcher writes watcher.json" "log: $(cat "$WLOG")"
fi

printf 'zz Documents\n' > "$GDRIVE_CONF_DIR/folders.txt.new"
mv "$GDRIVE_CONF_DIR/folders.txt.new" "$GDRIVE_CONF_DIR/folders.txt"
if wait_for 15 sh -c "! kill -0 $WATCH_PID 2>/dev/null"; then
  wait "$WATCH_PID"; wrc=$?
  assert_rc "a folders.txt change still ends the watcher with 0" 0 "$wrc"
else
  fail "a folders.txt change still ends the watcher with 0" "the watcher did not exit"
  kill "$WATCH_PID" 2>/dev/null
fi
WATCH_PID=""
assert_jq "a clean exit leaves the state stopped" stopped "$WATCHER" '.state'
assert_json "the stopped file is valid JSON" "$WATCHER"

finish
