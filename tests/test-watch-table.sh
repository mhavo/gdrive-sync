#!/usr/bin/env bash
# §3.3 path -> folder, §3.6/R12 quoting and word splitting.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_sandbox
trap cleanup_sandbox EXIT

R="$SANDBOX/local"

# A fake gdrive-sync: --list-paths prints the fixture table. This way the table
# can contain things folders.txt would not allow (a trailing space), and
# read -r / IFS are genuinely exercised.
TABLE_FILE="$SANDBOX/table.tsv"
cat > "$SANDBOX/fake-sync" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--list-paths" ]]; then
  cat "$TABLE_FILE"
  exit "\${FAKE_LIST_RC:-0}"
fi
exit 0
EOF
chmod +x "$SANDBOX/fake-sync"
export GDRIVE_SYNC_BIN="$SANDBOX/fake-sync"

printf '%s\t%s\n' \
  "$R/Documents"      "Documents" \
  "$R/Projects"       "Projects" \
  "$R/Projects/2026"  "Projects/2026" \
  "$R/Tickler"        "Tickler" \
  "$R/Tickler-old"    "Tickler-old" \
  "$R/Rusty Armour"   "Rusty Armour" \
  "$R/Naïve Café"     "Naïve Café" \
  "$R/Photos [2026]"  "Photos [2026]" \
  "$R/Trailing "      "Trailing " \
  > "$TABLE_FILE"

# shellcheck source=gdrive-watch
source "$GDRIVE_WATCH"

build_table
rc=$?
assert_rc "build_table succeeds" 0 "$rc"
assert_eq "9 rows in the table" 9 "${#DIRS[@]}"
assert_eq "as many directories as --only= values" "${#DIRS[@]}" "${#ONLYS[@]}"
assert_eq "name with a space kept whole" "$R/Rusty Armour" "${DIRS[5]}"
assert_eq "trailing space survives" "$R/Trailing " "${DIRS[8]}"
assert_eq "--only= value with a trailing space" "Trailing " "${ONLYS[8]}"

t() { # t <name> <expected> <path>
  local name="$1" expected="$2" path="$3" got
  got="$(folder_for_path "$path")" || got="<no match>"
  assert_eq "$name" "$expected" "$got"
}

t "the directory itself"        "Documents"     "$R/Documents"
t "a file in the folder"        "Documents"     "$R/Documents/note.md"
t "a file in a subdirectory"    "Documents"     "$R/Documents/2026/q1/report.odt"
t "longest match wins"          "Projects/2026" "$R/Projects/2026/plan.md"
t "shorter match when the longer does not apply" "Projects" "$R/Projects/2025/old.md"
t "no match from outside the root" "<no match>"  "/etc/passwd"
t "no match from the root itself"  "<no match>"  "$R/loose.txt"
t "prefix trap: Tickler-old"       "Tickler-old" "$R/Tickler-old/a.md"
t "prefix trap: Tickler"           "Tickler"     "$R/Tickler/a.md"
t "name with a space"              "Rusty Armour" "$R/Rusty Armour/shield.jpg"
t "non-ASCII name"                 "Naïve Café"   "$R/Naïve Café/demo.flac"
t "bracketed name taken literally" "Photos [2026]" "$R/Photos [2026]/photo.jpg"
t "a bracket does not act as a character class" "<no match>" "$R/Photos 2/photo.jpg"
t "trailing space"                 "Trailing "    "$R/Trailing /a.md"

# --- R10: startup failure ----------------------------------------------------
: > "$TABLE_FILE"
out="$(build_table 2>&1)"; rc=$?
assert_rc "empty table -> build_table fails" 1 "$rc"
assert_contains "empty table -> reason logged" "$out" "empty"

printf '%s\t%s\n' "$R/Documents" "Documents" > "$TABLE_FILE"
out="$(FAKE_LIST_RC=1 build_table 2>&1)"; rc=$?
assert_rc "--list-paths error -> build_table fails" 1 "$rc"
assert_contains "--list-paths error -> reason logged" "$out" "--list-paths"

finish
