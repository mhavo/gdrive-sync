#!/usr/bin/env bash
# §3.4 draining and exit codes, §3.2 choosing the wait interval.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_sandbox
trap cleanup_sandbox EXIT

ARGS_LOG="$SANDBOX/args.log"
RC_FILE="$SANDBOX/rc"
echo 0 > "$RC_FILE"

cat > "$SANDBOX/fake-sync" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--list-paths" ]]; then exit 0; fi
{ printf 'argc=%s\n' "\$#"; printf 'arg=%s\n' "\$@"; } >> "$ARGS_LOG"
echo "CHILD JUNK on stdout"
echo "CHILD JUNK on stderr" >&2
exit "\$(cat "$RC_FILE")"
EOF
chmod +x "$SANDBOX/fake-sync"
export GDRIVE_SYNC_BIN="$SANDBOX/fake-sync"

# shellcheck source=gdrive-watch
source "$GDRIVE_WATCH"

# The array is named keys, not out: the file scope uses out for captured output,
# and reusing the name makes an array and a string look like one variable.
dirty_keys() {
  local k keys=()
  for k in "${!DIRTY[@]}"; do keys+=("$k"); done
  printf '%s\n' "${keys[@]+"${keys[@]}"}" | LC_ALL=C sort | grep -v '^$' | paste -sd'|'
}

# --- Exit codes --------------------------------------------------------------
DIRTY=(); DIRTY["Documents"]=1
echo 0 > "$RC_FILE"; drain >/dev/null 2>&1
assert_eq "exit 0 removes from the set" "" "$(dirty_keys)"

DIRTY=(); DIRTY["Documents"]=1
echo 75 > "$RC_FILE"; drain >/dev/null 2>&1
assert_eq "exit 75 keeps it in the set" "Documents" "$(dirty_keys)"

DIRTY=(); DIRTY["Documents"]=1
echo 3 > "$RC_FILE"; drain >/dev/null 2>&1
assert_eq "any other error removes from the set" "" "$(dirty_keys)"

# Associative-array subscripts must remain data when a key is removed. In Bash,
# interpolating the key into an unset expression evaluates command substitutions
# a second time and can also leave the key stuck in the dirty set.
# shellcheck disable=SC2016
literal_substitution='$(printf WATCHER_COMMAND_EXECUTED >&2)'
DIRTY=(); DIRTY["$literal_substitution"]=1
handle_rc "$literal_substitution" 0 > "$SANDBOX/handle-rc.log" 2>&1
out="$(cat "$SANDBOX/handle-rc.log")"
assert_eq "shell syntax in a folder name is removed literally" "" "$(dirty_keys)"
if [[ "$out" == WATCHER_COMMAND_EXECUTED* || "$out" == *"bad array subscript"* ]]; then
  fail "shell syntax in a folder name is not evaluated" "got: [$out]"
else
  pass "shell syntax in a folder name is not evaluated"
fi

echo 3 > "$RC_FILE"
DIRTY=(); DIRTY["Documents"]=1
out="$(drain 2>&1)"
assert_contains "any other error is logged with its code" "$out" "3"

# --- §7: the child's output reaches the journal ------------------------------
# It used to be discarded, because gdrive-sync wrote a log file of its own and
# nothing was lost. With logging moved to the journal, discarding it would leave
# a watcher-triggered sync recorded by nothing but its exit code, while the same
# run under the timer is logged in full.
echo 0 > "$RC_FILE"
DIRTY=(); DIRTY["Documents"]=1
out="$(drain 2>&1)"
assert_contains "the child's output reaches the watcher's stdout" "$out" "CHILD JUNK"

# --- R12: --only= as one word, the name unchanged ---------------------------
echo 0 > "$RC_FILE"
for name in "${HOSTILE_NAMES[@]}" "Trailing " "zz id test"; do
  : > "$ARGS_LOG"
  DIRTY=(); DIRTY["$name"]=1
  drain >/dev/null 2>&1
  expected="argc=1
arg=--only=$name"
  assert_eq "--only= as one word: [$name]" "$expected" "$(cat "$ARGS_LOG")"
  assert_eq "the set emptied: [$name]" "" "$(dirty_keys)"
done

# 75 keeps even a hostile name in the set unchanged
echo 75 > "$RC_FILE"
for name in "${HOSTILE_NAMES[@]}"; do
  DIRTY=(); DIRTY["$name"]=1
  drain >/dev/null 2>&1
  assert_eq "75 keeps the name unchanged: [$name]" "$name" "$(dirty_keys)"
done

# Several folders at once: only the one that hit the lock stays
echo 0 > "$RC_FILE"
DIRTY=(); DIRTY["Documents"]=1; DIRTY["Rusty Armour"]=1; DIRTY["Naïve Café"]=1
drain >/dev/null 2>&1
assert_eq "all successful ones are removed" "" "$(dirty_keys)"

# --- §3.2 choosing the wait interval ----------------------------------------
assert_eq "debounce default" 5 "$DEBOUNCE_SEC"
assert_eq "retry default" 30 "$RETRY_SEC"
DIRTY=(); RETRY_PENDING=0
assert_eq "empty set -> debounce" 5 "$(next_wait)"
DIRTY=(); DIRTY["Documents"]=1; RETRY_PENDING=0
assert_eq "just gone dirty -> debounce" 5 "$(next_wait)"
DIRTY=(); DIRTY["Documents"]=1; RETRY_PENDING=1
assert_eq "retry pending -> retry" 30 "$(next_wait)"

# Draining sets the retry state itself
echo 75 > "$RC_FILE"
DIRTY=(); DIRTY["Documents"]=1; RETRY_PENDING=0
drain >/dev/null 2>&1
assert_eq "75 leaves the retry pending" 1 "$RETRY_PENDING"
echo 0 > "$RC_FILE"
DIRTY=(); DIRTY["Documents"]=1; RETRY_PENDING=1
drain >/dev/null 2>&1
assert_eq "an emptied set clears the retry" 0 "$RETRY_PENDING"

finish
