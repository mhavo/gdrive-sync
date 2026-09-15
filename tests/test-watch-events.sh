#!/usr/bin/env bash
# §3.1 exclude pattern and config-directory events, §3.5 folders.txt.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_sandbox
trap cleanup_sandbox EXIT

export GDRIVE_SYNC_BIN="/bin/true"
# shellcheck source=gdrive-watch
source "$GDRIVE_WATCH"

# --- Exclude pattern (inotify's own, not rclone's filter.txt) ---------------
for p in 'note.md~' 'file.swp' 'download.tmp' 'big.partial' 'a.crdownload' \
         'photo.conflict1' 'photo.conflict'; do
  if [[ "$p" =~ $EXCLUDE_RE ]]; then
    pass "skipped: $p"
  else
    fail "skipped: $p" "pattern: $EXCLUDE_RE"
  fi
done

for p in 'note.md' 'Rusty Armour/shield.jpg' 'Naïve Café/demo.flac' \
         'report.tmpx' 'swap.swpp'; do
  if [[ "$p" =~ $EXCLUDE_RE ]]; then
    fail "not skipped: $p" "pattern: $EXCLUDE_RE"
  else
    pass "not skipped: $p"
  fi
done

# --- §3.1/§3.5: only folders.txt in the config dir triggers a reread ---------
is() { # is <name> <expected: yes|no> <path>
  local name="$1" expected="$2" path="$3" got
  if is_folders_event "$path"; then got=yes; else got=no; fi
  assert_eq "$name" "$expected" "$got"
}

is "folders.txt in the config directory" yes "$GDRIVE_CONF_DIR/folders.txt"
is "folders.txt temporary file"          no  "$GDRIVE_CONF_DIR/folders.txt.swp"
is "config.env does not trigger"         no  "$GDRIVE_CONF_DIR/config.env"
is "filter.txt does not trigger"         no  "$GDRIVE_CONF_DIR/filter.txt"
is "same name elsewhere does not trigger" no "$GDRIVE_LOCAL/Documents/folders.txt"

finish
