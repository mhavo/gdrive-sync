#!/usr/bin/env bash
# §2 (exit code 75) and R5 (regressions from the load_lines refactor).
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_sandbox
trap cleanup_sandbox EXIT

write_folders <<'EOF'
Documents
Rusty Armour
id:0BwyG7PLuwLCCWTR0UWJVc2kzQ0k  zz id test
EOF

# --- §2: lock contention ----------------------------------------------------
exec 9>"$GDRIVE_STATE_DIR/lock"
flock -x 9
out="$("$GDRIVE_SYNC" 2>&1)"; rc=$?
flock -u 9
exec 9>&-

assert_rc "lock contention exits with 75" 75 "$rc"
assert_contains "lock message unchanged" "$out" "gdrive-sync is already running, skipping."

# --- R5: --status without the network ---------------------------------------
# The test-wide rclone double also covers the explicit-ID row, so this never
# reaches the user's remote or credentials.
st="$("$GDRIVE_SYNC" --status 2>&1)"; rc_st=$?
assert_rc "--status succeeds" 0 "$rc_st"
assert_contains "--status: path line" "$st" "local     : $GDRIVE_LOCAL/Documents"
assert_contains "--status: name with a space" "$st" "local     : $GDRIVE_LOCAL/Rusty Armour"
assert_contains "--status: local name of an id: line" "$st" "local     : $GDRIVE_LOCAL/zz id test"
assert_contains "--status: the ID from the line" "$st" "0BwyG7PLuwLCCWTR0UWJVc2kzQ0k (given on the line)"
assert_contains "--status: unpinned" "$st" "NOT PINNED"

st_only="$("$GDRIVE_SYNC" --status --only='Rusty Armour' 2>&1)"
assert_eq "--status --only narrows to one" 1 "$(grep -c 'local     :' <<<"$st_only")"

# --- Destination identity ---------------------------------------------------
write_folders <<'EOF'
A B
A_B
EOF
export RCLONE_LSJSON='[
  {"Name":"A B","ID":"drive-id-space"},
  {"Name":"A_B","ID":"drive-id-underscore"}
]'
: > "$RCLONE_CALLS"
o="$("$GDRIVE_SYNC" --resync 2>&1)"; r=$?
assert_rc "colliding legacy slugs still sync both configured folders" 0 "$r"
assert_contains "space name uses its own Drive ID" "$(cat "$RCLONE_CALLS")" "GoogleDrive,root_folder_id=drive-id-space:"
assert_contains "underscore name uses its own Drive ID" "$(cat "$RCLONE_CALLS")" "GoogleDrive,root_folder_id=drive-id-underscore:"

write_folders <<'EOF'
Archive
id:archive-id  Archive
EOF
o="$("$GDRIVE_SYNC" --list-paths 2>&1)"; r=$?
assert_rc "two entries cannot target the same local folder" 1 "$r"
assert_contains "duplicate local folder has a clear error" "$o" "Duplicate local folder"

write_folders <<'EOF'
Documents
EOF
export RCLONE_LSJSON='[
  {"Name":"Documents","ID":"first-id"},
  {"Name":"Documents","ID":"second-id"}
]'
o="$("$GDRIVE_SYNC" 2>&1)"; r=$?
assert_rc "duplicate Drive names are rejected" 1 "$r"
assert_contains "duplicate Drive names explain the ambiguity" "$o" "ambiguous"

write_folders <<'EOF'
Projects/2026
EOF
export RCLONE_LSJSON_ROOT='[{"Name":"Projects","ID":"projects-id"}]'
export RCLONE_LSJSON_CHILD='[{"Name":"2026","ID":"year-id"}]'
: > "$RCLONE_CALLS"
o="$("$GDRIVE_SYNC" --resync 2>&1)"; r=$?
assert_rc "nested Drive path resolves one ID at each level" 0 "$r"
assert_contains "nested path syncs the resolved leaf ID" "$(cat "$RCLONE_CALLS")" "GoogleDrive,root_folder_id=year-id:"
unset RCLONE_LSJSON_ROOT RCLONE_LSJSON_CHILD

# A matching legacy marker is copied to the collision-resistant name and stays
# readable without resolving the folder again. The legacy file is retained so
# migration is recoverable.
write_folders <<'EOF'
Legacy Name
EOF
legacy_marker="$GDRIVE_STATE_DIR/initialized/Legacy_Name"
{
  printf 'id=legacy-id\n'
  printf 'name=Legacy Name\n'
  printf 'path=Legacy Name\n'
  printf 'pinned=2026-01-01T00:00:00+00:00\n'
} > "$legacy_marker"
export RCLONE_LSJSON='[]'
: > "$RCLONE_CALLS"
o="$("$GDRIVE_SYNC" 2>&1)"; r=$?
assert_rc "matching legacy marker migrates" 0 "$r"
assert_contains "legacy marker keeps its Drive ID" "$(cat "$RCLONE_CALLS")" "GoogleDrive,root_folder_id=legacy-id:"
assert_eq "legacy migration leaves a recoverable old marker and a new marker" 2 \
  "$(grep -rl '^path=Legacy Name$' "$GDRIVE_STATE_DIR/initialized" | wc -l)"

# --- Durable first-run initialization --------------------------------------
write_folders <<'EOF'
Documents
EOF
export RCLONE_LSJSON='[{"Name":"Documents","ID":"documents-id"}]'
export RCLONE_LSF_RC=1
o="$("$GDRIVE_SYNC" 2>&1)"; r=$?
assert_rc "first remote-probe failure is reported" 1 "$r"
documents_hash="$(printf Documents | sha256sum | sed 's/[[:space:]].*//')"
marker="$GDRIVE_STATE_DIR/initialized/path_$documents_hash"
assert_contains "failed first run keeps resync pending" "$(cat "$marker")" "resync=1"

export RCLONE_LSF_RC=0
: > "$RCLONE_CALLS"
o="$("$GDRIVE_SYNC" 2>&1)"; r=$?
assert_rc "retry after first-run failure succeeds" 0 "$r"
assert_contains "retry performs the required resync" "$(cat "$RCLONE_CALLS")" "arg=--resync"

# --- Dry-run contract -------------------------------------------------------
write_folders <<'EOF'
Dry Preview
EOF
export RCLONE_LSJSON='[{"Name":"Dry Preview","ID":"preview-id"}]'
markers_before="$(find "$GDRIVE_STATE_DIR/initialized" -type f -print 2>/dev/null | sort)"
o="$("$GDRIVE_SYNC" -n 2>&1)"; r=$?
assert_rc "dry-run succeeds" 0 "$r"
if [[ -e "$GDRIVE_LOCAL/Dry Preview" ]]; then
  fail "dry-run does not create the selected local folder"
else
  pass "dry-run does not create the selected local folder"
fi
assert_eq "dry-run creates no marker" "$markers_before" "$(find "$GDRIVE_STATE_DIR/initialized" -type f -print 2>/dev/null | sort)"

# --- Logging is the journal's, not a file's ---------------------------------
# rclone gets no --log-file and the script writes none, so a real run must leave
# nothing behind under the state directory but the state it needs. Checked after
# a run that syncs, because that is the only path that ever opened a log file.
write_folders <<'EOF'
Documents
EOF
export RCLONE_LSJSON='[{"Name":"Documents","ID":"documents-id"}]'
: > "$RCLONE_CALLS"
o="$("$GDRIVE_SYNC" 2>&1)"; r=$?
assert_rc "a real run succeeds" 0 "$r"
assert_no_path "a run creates no logs directory" "$GDRIVE_STATE_DIR/logs"
assert_eq "a run writes no log file anywhere in the state directory" "" \
  "$(find "$GDRIVE_STATE_DIR" -name '*.log' -print 2>/dev/null)"
assert_eq "rclone is called without --log-file" "" \
  "$(grep -F -- '--log-file' "$RCLONE_CALLS")"
assert_contains "rclone still gets --log-level INFO" "$(cat "$RCLONE_CALLS")" "arg=--log-level"

# --- R5: a missing and an empty folder list keep their message and code ------
for action in --status --repin -n; do
  mv "$GDRIVE_CONF_DIR/folders.txt" "$SANDBOX/folders.bak"
  o="$("$GDRIVE_SYNC" "$action" 2>&1)"; r=$?
  mv "$SANDBOX/folders.bak" "$GDRIVE_CONF_DIR/folders.txt"
  assert_rc "$action: missing list -> 1" 1 "$r"
  assert_contains "$action: missing list -> message" "$o" "Folder list not found"

  cp "$GDRIVE_CONF_DIR/folders.txt" "$SANDBOX/folders.bak"
  printf '# comment only\n' > "$GDRIVE_CONF_DIR/folders.txt"
  o="$("$GDRIVE_SYNC" "$action" 2>&1)"; r=$?
  cp "$SANDBOX/folders.bak" "$GDRIVE_CONF_DIR/folders.txt"
  assert_rc "$action: empty list -> 1" 1 "$r"
  assert_contains "$action: empty list -> message" "$o" "Folder list is empty"
done

# --- R5: unknown option unchanged -------------------------------------------
o="$("$GDRIVE_SYNC" --does-not-exist 2>&1)"; r=$?
assert_rc "unknown option -> 2" 2 "$r"
assert_contains "unknown option -> message" "$o" "Unknown option: --does-not-exist"

finish
