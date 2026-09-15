#!/usr/bin/env bash
# §1: gdrive-sync --list-paths
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_sandbox
trap cleanup_sandbox EXIT

L="$GDRIVE_LOCAL"

write_folders <<'EOF'
# A comment line is skipped

Documents
Projects/2026
Rusty Armour
Naïve Café
Photos [2026]
id:0BwyG7PLuwLCCWTR0UWJVc2kzQ0k  zz id test
Documents2   # end-of-line comment
EOF

out="$("$GDRIVE_SYNC" --list-paths)"; rc=$?

assert_rc "--list-paths succeeds" 0 "$rc"

expected="$L/Documents	Documents
$L/Projects/2026	Projects/2026
$L/Rusty Armour	Rusty Armour
$L/Naïve Café	Naïve Café
$L/Photos [2026]	Photos [2026]
$L/zz id test	zz id test
$L/Documents2	Documents2"

assert_eq "table in line order, tab separated" "$expected" "$out"

# Every line is split by a tab into exactly two fields
bad=0
while IFS= read -r line; do
  [[ "$(awk -F'\t' '{print NF}' <<<"$line")" == "2" ]] || bad=1
done <<<"$out"
assert_eq "exactly two tab fields per line" 0 "$bad"

# --- R6: no lock, no jq, no state files -------------------------------------

# Lock held: --list-paths still works
exec 9>"$GDRIVE_STATE_DIR/lock"
flock -x 9
out_locked="$("$GDRIVE_SYNC" --list-paths)"; rc_locked=$?
flock -u 9
exec 9>&-
assert_rc "works while the lock is held" 0 "$rc_locked"
assert_eq "same output while the lock is held" "$expected" "$out_locked"

# jq off PATH
fakebin="$SANDBOX/bin"
mkdir -p "$fakebin"
for t in bash env sed grep awk; do
  p="$(command -v "$t")" && ln -sf "$p" "$fakebin/$t"
done
out_nojq="$(PATH="$fakebin" "$GDRIVE_SYNC" --list-paths 2>&1)"; rc_nojq=$?
assert_rc "works without jq" 0 "$rc_nojq"
assert_eq "same output without jq" "$expected" "$out_nojq"

# No state files: the sandbox state directory is left untouched
rm -rf "$GDRIVE_STATE_DIR"
"$GDRIVE_SYNC" --list-paths >/dev/null 2>&1
assert_eq "does not create the state directory" "no" "$([[ -d "$GDRIVE_STATE_DIR" ]] && echo yes || echo no)"
mkdir -p "$GDRIVE_STATE_DIR"

# --- Error cases -------------------------------------------------------------
write_folders <<'EOF'
# comments only
EOF
out_empty="$("$GDRIVE_SYNC" --list-paths 2>&1)"; rc_empty=$?
assert_rc "empty folder list: non-zero" 1 "$rc_empty"
assert_contains "empty folder list: message" "$out_empty" "Folder list is empty"

rm -f "$GDRIVE_CONF_DIR/folders.txt"
out_miss="$("$GDRIVE_SYNC" --list-paths 2>&1)"; rc_miss=$?
assert_rc "missing folder list: non-zero" 1 "$rc_miss"
assert_contains "missing folder list: message" "$out_miss" "Folder list not found"

# --- An invalid line must not stop the others from being watched ------------
# One broken line is reported on stderr, but the table is printed and the return
# value is 0: otherwise gdrive-watch would refuse to watch any folder at all.
write_folders <<'EOF'
Documents
id:
Archive
EOF
out_bad="$("$GDRIVE_SYNC" --list-paths 2>"$SANDBOX/err")"; rc_bad=$?
assert_rc "invalid line: others still listed (rc 0)" 0 "$rc_bad"
assert_eq "invalid line: the valid lines" "$L/Documents	Documents
$L/Archive	Archive" "$out_bad"
assert_contains "invalid line: reason on stderr" "$(cat "$SANDBOX/err")" "Invalid line"

write_folders <<'EOF'
id:
EOF
out_allbad="$("$GDRIVE_SYNC" --list-paths 2>/dev/null)"; rc_allbad=$?
assert_rc "only invalid lines -> non-zero" 1 "$rc_allbad"
assert_eq "only invalid lines -> empty output" "" "$out_allbad"

# --- Help text ---------------------------------------------------------------
help_out="$("$GDRIVE_SYNC" --help)"
assert_contains "--help mentions --list-paths" "$help_out" "--list-paths"

finish
