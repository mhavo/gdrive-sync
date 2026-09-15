#!/usr/bin/env bash
# install.sh: it must install what it promises, overwrite nothing of yours, and
# sync nothing at all.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL="$REPO_ROOT/install.sh"

# A sandbox of install targets, plus doubles for the commands that would
# otherwise reach the real session bus and the real desktop database.
make_install_sandbox() {
  make_sandbox
  export GDRIVE_BIN_DIR="$SANDBOX/bin"
  export GDRIVE_UNIT_DIR="$SANDBOX/units"
  export GDRIVE_DESKTOP_DIR="$SANDBOX/applications"
  export SYSTEMCTL_CALLS="$SANDBOX/systemctl-calls.log"
  : > "$SYSTEMCTL_CALLS"

  mkdir -p "$SANDBOX/fake-bin"
  cat > "$SANDBOX/fake-bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_CALLS"
FAKE
  cat > "$SANDBOX/fake-bin/update-desktop-database" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
  cat > "$SANDBOX/fake-bin/xdg-mime" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
  chmod +x "$SANDBOX/fake-bin"/*
  export PATH="$SANDBOX/fake-bin:$PATH"
}

# Extra environment for one run, as an array rather than a "VAR=x run_install"
# prefix: in bash an assignment in front of a *function* call outlives the call,
# and a leaked RCLONE_LSD_RC would quietly reshape every test after it.
INSTALL_ENV=()

run_install() {
  env "${INSTALL_ENV[@]}" "$INSTALL" "$@" >"$SANDBOX/out" 2>"$SANDBOX/err"
  INSTALL_RC=$?
  INSTALL_OUT="$(cat "$SANDBOX/out" "$SANDBOX/err")"
  INSTALL_ENV=()
}

# A PATH with the handful of commands install.sh itself uses and nothing else,
# so "rclone is missing" is tested without the real rclone one directory along
# reaching the user's real remote.
make_min_path() {
  local cmd
  mkdir -p "$SANDBOX/min-bin"
  for cmd in bash cat mkdir cp chmod ln readlink rm grep; do
    ln -sf "$(command -v "$cmd")" "$SANDBOX/min-bin/$cmd"
  done
  printf '%s' "$SANDBOX/min-bin"
}

# --- A dry run changes nothing ----------------------------------------------
make_install_sandbox
run_install --dry-run -y
assert_rc "dry run succeeds" 0 "$INSTALL_RC"
assert_contains "dry run says so" "$INSTALL_OUT" "Dry run: nothing is changed."
assert_no_path "dry run creates no symlink" "$GDRIVE_BIN_DIR/gdrive-sync"
assert_no_path "dry run installs no unit" "$GDRIVE_UNIT_DIR/gdrive-sync.timer"
assert_eq "dry run calls no systemctl" "" "$(cat "$SYSTEMCTL_CALLS")"
cleanup_sandbox

# --- A real install ---------------------------------------------------------
make_install_sandbox
rm -f "$GDRIVE_CONF_DIR/filter.txt"      # make_sandbox creates it; test the copy
run_install --no-enable
assert_rc "install succeeds" 0 "$INSTALL_RC"

for name in gdrive-sync gdrive-watch open-url-shortcut; do
  if [[ -L "$GDRIVE_BIN_DIR/$name" ]]; then
    assert_eq "$name links into the repo" \
      "$REPO_ROOT/$name" "$(readlink -f "$GDRIVE_BIN_DIR/$name")"
  else
    fail "$name links into the repo" "not a symlink"
  fi
done

for f in folders.txt filter.txt config.env; do
  assert_path "$f installed" "$GDRIVE_CONF_DIR/$f"
done
assert_eq "config.env is chmod 600" "600" "$(stat -c %a "$GDRIVE_CONF_DIR/config.env")"

for unit in gdrive-sync.service gdrive-sync.timer gdrive-watch.service; do
  assert_path "$unit installed" "$GDRIVE_UNIT_DIR/$unit"
done
assert_path "desktop entry installed" "$GDRIVE_DESKTOP_DIR/url-shortcut.desktop"

# The one guarantee the whole script rests on.
assert_eq "install runs no rclone bisync" "" "$(grep -c '^command=bisync$' "$RCLONE_CALLS" | grep -v '^0$')"
assert_contains "the remote was checked" "$(cat "$RCLONE_CALLS")" "command=lsd"

# --- Installing twice is not an error, and keeps your files -----------------
printf 'MyFolder\n' > "$GDRIVE_CONF_DIR/folders.txt"
run_install --no-enable
assert_rc "second install succeeds" 0 "$INSTALL_RC"
assert_eq "folders.txt kept as it is" "MyFolder" "$(cat "$GDRIVE_CONF_DIR/folders.txt")"
assert_contains "already-linked is reported" "$INSTALL_OUT" "already linked here"
cleanup_sandbox

# --- Enabling is gated on folders.txt actually having folders ---------------
make_install_sandbox
run_install -y
assert_contains "empty folders.txt does not enable the timer" \
  "$INSTALL_OUT" "has no folders in it yet"
assert_eq "and calls no enable" "" "$(grep 'enable' "$SYSTEMCTL_CALLS")"
cleanup_sandbox

make_install_sandbox
mkdir -p "$GDRIVE_CONF_DIR"
printf 'Documents\n' > "$GDRIVE_CONF_DIR/folders.txt"
run_install -y
assert_contains "a configured folders.txt enables the timer" \
  "$(cat "$SYSTEMCTL_CALLS")" "enable --now gdrive-sync.timer"
assert_contains "and the watcher" \
  "$(cat "$SYSTEMCTL_CALLS")" "enable --now gdrive-watch.service"
cleanup_sandbox

# --- --no-watcher -----------------------------------------------------------
make_install_sandbox
run_install --no-watcher --no-enable
assert_no_path "--no-watcher leaves out the symlink" "$GDRIVE_BIN_DIR/gdrive-watch"
assert_no_path "--no-watcher leaves out the unit" "$GDRIVE_UNIT_DIR/gdrive-watch.service"
assert_path "--no-watcher still installs the timer" "$GDRIVE_UNIT_DIR/gdrive-sync.timer"
cleanup_sandbox

# --- A dead remote stops the install ----------------------------------------
make_install_sandbox
INSTALL_ENV=(RCLONE_LSD_RC=1)
run_install --no-enable
assert_rc "a failing remote fails the install" 1 "$INSTALL_RC"
assert_contains "and says which remote" "$INSTALL_OUT" "does not answer"
assert_no_path "and installs nothing" "$GDRIVE_BIN_DIR/gdrive-sync"

INSTALL_ENV=(RCLONE_LSD_RC=1)
run_install --skip-remote-check --no-enable
assert_rc "--skip-remote-check installs anyway" 0 "$INSTALL_RC"
cleanup_sandbox

# --- A missing dependency stops the install ---------------------------------
make_install_sandbox
INSTALL_ENV=("PATH=$(make_min_path)")
run_install --no-enable
assert_rc "a missing rclone fails the install" 1 "$INSTALL_RC"
assert_contains "and names the command" "$INSTALL_OUT" "missing commands"
assert_contains "and names rclone" "$INSTALL_OUT" "rclone"
assert_no_path "and installs nothing" "$GDRIVE_BIN_DIR/gdrive-sync"
cleanup_sandbox

# --- Uninstall --------------------------------------------------------------
make_install_sandbox
run_install --no-enable
printf 'MyFolder\n' > "$GDRIVE_CONF_DIR/folders.txt"
run_install --uninstall -y
assert_rc "uninstall succeeds" 0 "$INSTALL_RC"
for name in gdrive-sync gdrive-watch open-url-shortcut; do
  assert_no_path "uninstall removes $name" "$GDRIVE_BIN_DIR/$name"
done
assert_no_path "uninstall removes the units" "$GDRIVE_UNIT_DIR/gdrive-sync.timer"
assert_eq "uninstall keeps folders.txt" "MyFolder" "$(cat "$GDRIVE_CONF_DIR/folders.txt")"
assert_contains "uninstall disables the units" \
  "$(cat "$SYSTEMCTL_CALLS")" "disable --now gdrive-sync.timer"

# A symlink that points somewhere else is not ours to remove.
mkdir -p "$GDRIVE_BIN_DIR"
ln -s /bin/true "$GDRIVE_BIN_DIR/gdrive-sync"
run_install --uninstall -y
assert_path "a foreign symlink is left alone" "$GDRIVE_BIN_DIR/gdrive-sync"
cleanup_sandbox

finish
