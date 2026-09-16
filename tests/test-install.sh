#!/usr/bin/env bash
# install.sh: it must install what it promises, overwrite nothing of yours, and
# sync nothing at all. With profiles there are two phases to check separately:
# the machine setup, which creates no profile, and profile creation, which
# touches one profile and no other.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL="$REPO_ROOT/install.sh"

# A sandbox of install targets, plus doubles for the commands that would
# otherwise reach the real session bus and the real desktop database.
make_install_sandbox() {
  make_sandbox
  # install.sh addresses profiles under the two roots. The single-directory
  # variables make_sandbox exports would name a profile that does not exist,
  # so they are cleared here rather than being half-honoured.
  unset GDRIVE_CONF_DIR GDRIVE_STATE_DIR GDRIVE_LOCAL
  export GDRIVE_CONF_ROOT="$SANDBOX/conf-root"
  export GDRIVE_STATE_ROOT="$SANDBOX/state-root"
  export GDRIVE_BIN_DIR="$SANDBOX/bin"
  export GDRIVE_UNIT_DIR="$SANDBOX/units"
  export GDRIVE_DESKTOP_DIR="$SANDBOX/applications"
  export SYSTEMCTL_CALLS="$SANDBOX/systemctl-calls.log"
  : > "$SYSTEMCTL_CALLS"
  mkdir -p "$GDRIVE_CONF_ROOT"

  mkdir -p "$SANDBOX/fake-bin"
  # is-enabled has to answer something: --list reports what it says, and a
  # double that only logged the call would make that column untestable.
  cat > "$SANDBOX/fake-bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_CALLS"
for arg in "$@"; do
  if [[ "$arg" == "is-enabled" ]]; then
    state="${SYSTEMCTL_IS_ENABLED:-disabled}"
    printf '%s\n' "$state"
    [[ "$state" == "enabled" ]] || exit 1
  fi
done
exit 0
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

# The three template unit files, and the instance names an enabled profile has.
TEMPLATES=(gdrive-sync@.service gdrive-sync@.timer gdrive-watch@.service)

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
  for cmd in bash cat mkdir cp chmod ln readlink rm grep sed realpath; do
    ln -sf "$(command -v "$cmd")" "$SANDBOX/min-bin/$cmd"
  done
  printf '%s' "$SANDBOX/min-bin"
}

# Enabling an instance is a systemctl symlink, not a file of its own, so a test
# that wants to see a per-profile uninstall remove something has to put the
# symlinks where systemctl would.
fake_enablement() {
  local profile="$1"
  mkdir -p "$GDRIVE_UNIT_DIR/timers.target.wants" "$GDRIVE_UNIT_DIR/default.target.wants"
  ln -sf "$GDRIVE_UNIT_DIR/gdrive-sync@.timer" \
    "$GDRIVE_UNIT_DIR/timers.target.wants/gdrive-sync@$profile.timer"
  ln -sf "$GDRIVE_UNIT_DIR/gdrive-watch@.service" \
    "$GDRIVE_UNIT_DIR/default.target.wants/gdrive-watch@$profile.service"
}

# --- A dry run changes nothing ----------------------------------------------
make_install_sandbox
run_install --dry-run -y
assert_rc "dry run succeeds" 0 "$INSTALL_RC"
assert_contains "dry run says so" "$INSTALL_OUT" "Dry run: nothing is changed."
assert_no_path "dry run creates no symlink" "$GDRIVE_BIN_DIR/gdrive-sync"
assert_no_path "dry run installs no unit" "$GDRIVE_UNIT_DIR/gdrive-sync@.timer"
assert_eq "dry run calls no systemctl" "" "$(cat "$SYSTEMCTL_CALLS")"
cleanup_sandbox

# --- The machine phase: everything that is not profile-specific -------------
make_install_sandbox
run_install
assert_rc "machine install succeeds" 0 "$INSTALL_RC"

for name in gdrive-sync gdrive-watch open-url-shortcut; do
  if [[ -L "$GDRIVE_BIN_DIR/$name" ]]; then
    assert_eq "$name links into the repo" \
      "$REPO_ROOT/$name" "$(readlink -f "$GDRIVE_BIN_DIR/$name")"
  else
    fail "$name links into the repo" "not a symlink"
  fi
done

for unit in "${TEMPLATES[@]}"; do
  assert_path "$unit installed" "$GDRIVE_UNIT_DIR/$unit"
done
assert_path "desktop entry installed" "$GDRIVE_DESKTOP_DIR/url-shortcut.desktop"

assert_eq "the machine phase creates no profile" "" "$(ls -A "$GDRIVE_CONF_ROOT")"
assert_eq "and checks no remote" "" "$(grep 'command=lsd' "$RCLONE_CALLS")"
assert_contains "and says how to create the first profile" \
  "$INSTALL_OUT" "--profile="

# The one guarantee the whole script rests on.
assert_eq "install runs no rclone bisync" "" "$(grep -c '^command=bisync$' "$RCLONE_CALLS" | grep -v '^0$')"

# --- Creating a profile -----------------------------------------------------
run_install --profile=work --remote=GDriveWork --local="$SANDBOX/data/work" --no-enable
assert_rc "profile creation succeeds" 0 "$INSTALL_RC"
for f in folders.txt filter.txt config.env; do
  assert_path "work: $f installed" "$GDRIVE_CONF_ROOT/work/$f"
done
assert_contains "work: config.env names the remote" \
  "$(cat "$GDRIVE_CONF_ROOT/work/config.env")" "GDRIVE_REMOTE=GDriveWork"
assert_contains "work: config.env names the local root" \
  "$(cat "$GDRIVE_CONF_ROOT/work/config.env")" "GDRIVE_LOCAL=$SANDBOX/data/work"
assert_eq "work: config.env is chmod 600" \
  "600" "$(stat -c %a "$GDRIVE_CONF_ROOT/work/config.env")"
assert_contains "work: the remote checked is this profile's" \
  "$(cat "$RCLONE_CALLS")" "arg=GDriveWork:"
assert_eq "work: still no bisync" "" "$(grep -c '^command=bisync$' "$RCLONE_CALLS" | grep -v '^0$')"

# --- A second profile leaves the first alone --------------------------------
printf 'MyFolder\n' > "$GDRIVE_CONF_ROOT/work/folders.txt"
run_install --profile=personal --remote=GDrivePersonal --local="$SANDBOX/data/personal" --no-enable
assert_rc "second profile succeeds" 0 "$INSTALL_RC"
assert_contains "personal: config.env names its own remote" \
  "$(cat "$GDRIVE_CONF_ROOT/personal/config.env")" "GDRIVE_REMOTE=GDrivePersonal"
assert_eq "work: folders.txt untouched by the second profile" \
  "MyFolder" "$(cat "$GDRIVE_CONF_ROOT/work/folders.txt")"
assert_contains "work: config.env untouched by the second profile" \
  "$(cat "$GDRIVE_CONF_ROOT/work/config.env")" "GDRIVE_REMOTE=GDriveWork"

# --- An existing folders.txt is never overwritten ---------------------------
run_install --profile=work --remote=GDriveWork --local="$SANDBOX/data/work" --no-enable
assert_eq "work: folders.txt kept as it is" \
  "MyFolder" "$(cat "$GDRIVE_CONF_ROOT/work/folders.txt")"
assert_contains "and says it kept it" "$INSTALL_OUT" "kept as it is"

# --- --list -----------------------------------------------------------------
INSTALL_ENV=(SYSTEMCTL_IS_ENABLED=enabled)
run_install --list
assert_rc "--list succeeds" 0 "$INSTALL_RC"
assert_contains "--list names the profile" "$INSTALL_OUT" "work"
assert_contains "--list names its remote" "$INSTALL_OUT" "GDriveWork"
assert_contains "--list names its local root" "$INSTALL_OUT" "$SANDBOX/data/work"
assert_contains "--list says whether the timer is enabled" "$INSTALL_OUT" "enabled"
assert_contains "--list lists the other profile too" "$INSTALL_OUT" "GDrivePersonal"
cleanup_sandbox

# --- Enabling is gated on that profile's folders.txt having folders ---------
make_install_sandbox
run_install
run_install --profile=work --remote=GDriveWork --local="$SANDBOX/data/work" -y
assert_contains "an empty folders.txt does not enable the timer" \
  "$INSTALL_OUT" "has no folders in it yet"
assert_eq "and calls no enable" "" "$(grep 'enable' "$SYSTEMCTL_CALLS")"

printf 'Documents\n' > "$GDRIVE_CONF_ROOT/work/folders.txt"
run_install --profile=work --remote=GDriveWork --local="$SANDBOX/data/work" -y
assert_contains "a configured folders.txt enables this profile's timer" \
  "$(cat "$SYSTEMCTL_CALLS")" "enable --now gdrive-sync@work.timer"
assert_contains "and this profile's watcher" \
  "$(cat "$SYSTEMCTL_CALLS")" "enable --now gdrive-watch@work.service"
cleanup_sandbox

# --- A colliding local root is refused before anything is written -----------
make_install_sandbox
run_install
run_install --profile=work --remote=GDriveWork --local="$SANDBOX/data/work" --no-enable
: > "$RCLONE_CALLS"

run_install --profile=nested --remote=GDriveNested --local="$SANDBOX/data/work/inside" --no-enable
assert_rc "a nested local root is refused" 1 "$INSTALL_RC"
assert_contains "and names the profile it collides with" "$INSTALL_OUT" "work"
assert_no_path "and writes nothing" "$GDRIVE_CONF_ROOT/nested"
assert_eq "and checks no remote first" "" "$(grep 'command=lsd' "$RCLONE_CALLS")"

run_install --profile=same --remote=GDriveSame --local="$SANDBOX/data/work" --no-enable
assert_rc "an identical local root is refused" 1 "$INSTALL_RC"
assert_no_path "and writes nothing either" "$GDRIVE_CONF_ROOT/same"
cleanup_sandbox

# --- --no-watcher -----------------------------------------------------------
make_install_sandbox
run_install --no-watcher
assert_no_path "--no-watcher leaves out the symlink" "$GDRIVE_BIN_DIR/gdrive-watch"
assert_no_path "--no-watcher leaves out the unit" "$GDRIVE_UNIT_DIR/gdrive-watch@.service"
assert_path "--no-watcher still installs the timer template" "$GDRIVE_UNIT_DIR/gdrive-sync@.timer"
cleanup_sandbox

# --- A dead remote stops the profile ----------------------------------------
make_install_sandbox
run_install
INSTALL_ENV=(RCLONE_LSD_RC=1)
run_install --profile=work --remote=GDriveWork --local="$SANDBOX/data/work" --no-enable
assert_rc "a failing remote fails the profile" 1 "$INSTALL_RC"
assert_contains "and says which remote" "$INSTALL_OUT" "does not answer"
assert_no_path "and creates no profile" "$GDRIVE_CONF_ROOT/work"

INSTALL_ENV=(RCLONE_LSD_RC=1)
run_install --profile=work --remote=GDriveWork --local="$SANDBOX/data/work" \
  --skip-remote-check --no-enable
assert_rc "--skip-remote-check creates it anyway" 0 "$INSTALL_RC"
cleanup_sandbox

# --- A missing dependency stops the install ---------------------------------
make_install_sandbox
INSTALL_ENV=("PATH=$(make_min_path)")
run_install
assert_rc "a missing rclone fails the install" 1 "$INSTALL_RC"
assert_contains "and names the command" "$INSTALL_OUT" "missing commands"
assert_contains "and names rclone" "$INSTALL_OUT" "rclone"
assert_no_path "and installs nothing" "$GDRIVE_BIN_DIR/gdrive-sync"
cleanup_sandbox

# --- Uninstalling one profile -----------------------------------------------
make_install_sandbox
run_install
run_install --profile=work --remote=GDriveWork --local="$SANDBOX/data/work" --no-enable
run_install --profile=personal --remote=GDrivePersonal --local="$SANDBOX/data/personal" --no-enable
fake_enablement work
fake_enablement personal
printf 'MyFolder\n' > "$GDRIVE_CONF_ROOT/work/folders.txt"

run_install --uninstall --profile=work -y
assert_rc "per-profile uninstall succeeds" 0 "$INSTALL_RC"
assert_contains "it disables that instance" \
  "$(cat "$SYSTEMCTL_CALLS")" "disable --now gdrive-sync@work.timer"
assert_no_path "it removes that instance's timer link" \
  "$GDRIVE_UNIT_DIR/timers.target.wants/gdrive-sync@work.timer"
assert_no_path "it removes that instance's watcher link" \
  "$GDRIVE_UNIT_DIR/default.target.wants/gdrive-watch@work.service"
assert_path "it leaves the other profile's timer link" \
  "$GDRIVE_UNIT_DIR/timers.target.wants/gdrive-sync@personal.timer"
assert_eq "it disables no other instance" "" "$(grep 'gdrive-sync@personal' "$SYSTEMCTL_CALLS")"
for unit in "${TEMPLATES[@]}"; do
  assert_path "it leaves the template $unit" "$GDRIVE_UNIT_DIR/$unit"
done
assert_path "it leaves the symlinks" "$GDRIVE_BIN_DIR/gdrive-sync"
assert_eq "it keeps that profile's folders.txt" \
  "MyFolder" "$(cat "$GDRIVE_CONF_ROOT/work/folders.txt")"
assert_path "it keeps the other profile's directory" "$GDRIVE_CONF_ROOT/personal"

# --- Uninstalling the machine -----------------------------------------------
run_install --uninstall -y
assert_rc "uninstall succeeds" 0 "$INSTALL_RC"
for name in gdrive-sync gdrive-watch open-url-shortcut; do
  assert_no_path "uninstall removes $name" "$GDRIVE_BIN_DIR/$name"
done
for unit in "${TEMPLATES[@]}"; do
  assert_no_path "uninstall removes the template $unit" "$GDRIVE_UNIT_DIR/$unit"
done
assert_no_path "uninstall removes the remaining instance link" \
  "$GDRIVE_UNIT_DIR/timers.target.wants/gdrive-sync@personal.timer"
assert_contains "uninstall disables every instance" \
  "$(cat "$SYSTEMCTL_CALLS")" "disable --now gdrive-sync@personal.timer"
assert_no_path "uninstall removes the desktop entry" \
  "$GDRIVE_DESKTOP_DIR/url-shortcut.desktop"
assert_path "uninstall keeps the profile directories" "$GDRIVE_CONF_ROOT/work"
assert_eq "uninstall keeps folders.txt" \
  "MyFolder" "$(cat "$GDRIVE_CONF_ROOT/work/folders.txt")"

# A symlink that points somewhere else is not ours to remove.
mkdir -p "$GDRIVE_BIN_DIR"
ln -s /bin/true "$GDRIVE_BIN_DIR/gdrive-sync"
run_install --uninstall -y
assert_path "a foreign symlink is left alone" "$GDRIVE_BIN_DIR/gdrive-sync"
cleanup_sandbox

finish
