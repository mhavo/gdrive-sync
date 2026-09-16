#!/usr/bin/env bash
# Installs gdrive-sync from this clone: symlinks on PATH, systemd unit
# templates, the .url desktop entry — and, one at a time, the profiles that
# hold each Google account's configuration.
#
# The script installs, it does not sync. It never runs bisync, never touches
# ~/GoogleDrive and never overwrites a config file you already have. The first
# sync stays a thing you start yourself, because that is the run where you want
# to be looking at the output.
#
# Everything it does is undone by --uninstall, and shown without doing it by
# --dry-run.
set -uo pipefail

VERSION="0.2.0"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Settings ---------------------------------------------------------------
# The installer works in roots, not in one configuration directory: a profile
# is a directory under them and nothing else, so the layout on disk is the only
# list of profiles there is.
CONF_ROOT="${GDRIVE_CONF_ROOT:-$HOME/.config/gdrive-sync}"
STATE_ROOT="${GDRIVE_STATE_ROOT:-$HOME/.local/state/gdrive-sync}"

# The Omarchy bar widget is distributed as a plugin, which omarchy clones into
# its own plugins directory. The installer neither installs nor removes it; it
# only looks, so it can say why the widget has nothing to show yet.
OMARCHY_PLUGIN_DIR="${GDRIVE_OMARCHY_PLUGIN_DIR:-$HOME/.config/omarchy/plugins/mhavo.gdrive-sync}"

BIN_DIR="${GDRIVE_BIN_DIR:-$HOME/.local/bin}"
UNIT_DIR="${GDRIVE_UNIT_DIR:-$HOME/.config/systemd/user}"
DESKTOP_DIR="${GDRIVE_DESKTOP_DIR:-$HOME/.local/share/applications}"

SCRIPTS=(gdrive-sync gdrive-watch open-url-shortcut)
DESKTOP_FILE="url-shortcut.desktop"
TEMPLATES=(gdrive-sync@.service gdrive-sync@.timer)
WATCH_TEMPLATE="gdrive-watch@.service"

ACTION="install"      # install | uninstall | list
PROFILE=""
REMOTE=""
LOCAL_ROOT=""
DRY_RUN=0
WITH_WATCHER=1
WITH_DESKTOP=1
CHECK_REMOTE=1
ENABLE_MODE="ask"     # ask | yes | no
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    -n|--dry-run)       DRY_RUN=1 ;;
    --uninstall)        ACTION="uninstall" ;;
    --list)             ACTION="list" ;;
    --profile=*)        PROFILE="${arg#--profile=}" ;;
    --remote=*)         REMOTE="${arg#--remote=}"; REMOTE="${REMOTE%:}" ;;
    --local=*)          LOCAL_ROOT="${arg#--local=}" ;;
    --no-watcher)       WITH_WATCHER=0 ;;
    --no-desktop)       WITH_DESKTOP=0 ;;
    --skip-remote-check) CHECK_REMOTE=0 ;;
    --no-enable)        ENABLE_MODE="no" ;;
    -y|--yes)           ASSUME_YES=1; [[ "$ENABLE_MODE" == "ask" ]] && ENABLE_MODE="yes" ;;
    -h|--help)
      cat <<HELP
install.sh [options]

Installs gdrive-sync from this clone. Syncs nothing; the first run stays yours.

There are two phases. Without --profile it sets the machine up once: symlinks,
the systemd unit templates, the desktop entry. With --profile it creates one
profile, which is one Google account's configuration:

  ./install.sh
  ./install.sh --profile=work --remote=GDriveWork --local=~/GoogleDrive/work

  -n, --dry-run     Print every step without performing any of it
      --profile=NAME
                    Create (or update) this profile. A name of [A-Za-z0-9._-]
      --remote=NAME This profile's rclone remote (default: GoogleDrive)
      --local=PATH  This profile's local root (default: \$HOME/GoogleDrive/NAME)
      --list        List the profiles, their remotes, roots and timers
      --uninstall   Remove what was installed. With --profile=NAME, only that
                      profile's units. Keeps synced data, config and state;
                      lists what it will remove and asks first
      --no-watcher  Leave out gdrive-watch and its unit
      --no-desktop  Leave out the .url desktop entry
      --skip-remote-check
                    Do not test the rclone remote first. Only for a machine
                      where the remote is set up later
      --no-enable   Install the systemd units without enabling them
  -y, --yes         Assume yes: enable the units, skip the uninstall prompt
  -h, --help        This help
  -V, --version     Print the version and exit

Install paths (environment):
  GDRIVE_BIN_DIR      $BIN_DIR
  GDRIVE_UNIT_DIR     $UNIT_DIR
  GDRIVE_DESKTOP_DIR  $DESKTOP_DIR
  GDRIVE_CONF_ROOT    $CONF_ROOT
  GDRIVE_STATE_ROOT   $STATE_ROOT
HELP
      exit 0 ;;
    -V|--version)       printf 'install.sh %s\n' "$VERSION"; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# --- Output -----------------------------------------------------------------
step() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   %s\n' "$*" >&2; }
die()  { printf '\nError: %s\n' "$*" >&2; exit 1; }

# Every change to the filesystem goes through this, so --dry-run is a property
# of one function rather than a flag checked in twenty places.
run() {
  if (( DRY_RUN )); then
    printf '   would: %s\n' "$*"
    return 0
  fi
  "$@"
}

confirm() {
  (( ASSUME_YES )) && return 0
  [[ -t 0 ]] || return 1
  local reply
  read -r -p "   $1 [y/N] " reply
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

have() { command -v "$1" >/dev/null 2>&1; }

# --- Profiles ---------------------------------------------------------------
# A name becomes both a path segment and a systemd instance name. Anything
# outside this set would demand systemd-escape and could escape the root.
profile_valid() {
  local name="$1"
  [[ -n "$name" && "$name" != "." && "$name" != ".." ]] || return 1
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]
}

# The directory scan lives in gdrive-sync, so the two cannot disagree about
# what a profile is. The scan below is the fallback for a clone whose script is
# not runnable here — the installer must still work on a bare machine.
list_profiles() {
  local out rc dir name
  out="$(GDRIVE_CONF_ROOT="$CONF_ROOT" "$REPO_DIR/gdrive-sync" --list-profiles 2>/dev/null)"
  rc=$?
  if (( rc == 0 )); then
    [[ -n "$out" ]] && printf '%s\n' "$out"
    return 0
  fi
  for dir in "$CONF_ROOT"/*/; do
    [[ -d "$dir" ]] || continue
    name="${dir%/}"; name="${name##*/}"
    profile_valid "$name" || continue
    printf '%s\n' "$name"
  done
}

# config.env is bash. Sourcing another profile's file into this shell would
# overwrite the settings of the profile being installed, so each one is read in
# a subshell that prints only the value asked for.
profile_value() {
  local name="$1" want="$2"
  ( set +u
    GDRIVE_REMOTE=""
    GDRIVE_LOCAL=""
    # shellcheck source=/dev/null
    [[ -r "$CONF_ROOT/$name/config.env" ]] && source "$CONF_ROOT/$name/config.env"
    case "$want" in
      remote) printf '%s\n' "${GDRIVE_REMOTE:-GoogleDrive}" ;;
      local)  printf '%s\n' "${GDRIVE_LOCAL:-$HOME/GoogleDrive/$name}" ;;
    esac )
}

# Two profiles under one local root means each one's bisync sees the other's
# files as local changes and carries their absence to its own Drive. The
# failure is silent and bidirectional, so it is refused before the profile
# directory exists at all.
#
# realpath first: a symlink must not be able to hide a nesting relationship.
check_local_collision() {
  step "Local root $LOCAL_ROOT"
  local mine other name
  mine="$(realpath -m -- "$LOCAL_ROOT")"
  while IFS= read -r name; do
    [[ -n "$name" && "$name" != "$PROFILE" ]] || continue
    other="$(realpath -m -- "$(profile_value "$name" local)")"
    if [[ "$mine" == "$other" || "$mine" == "$other"/* || "$other" == "$mine"/* ]]; then
      warn "Local root collision with profile '$name':"
      warn "  $PROFILE: $mine"
      warn "  $name: $other"
      warn "Two profiles may not share or nest their local roots: each one's"
      warn "sync would see the other's files as deletions."
      die "'$LOCAL_ROOT' collides with profile '$name'"
    fi
  done < <(list_profiles)
  info "no collision with another profile"
}

# --- Dependencies -----------------------------------------------------------
# Reported, never installed. Which package carries which command differs by
# distribution, and an installer that runs the package manager for you is doing
# something you did not ask it to do as root.
check_deps() {
  step "Dependencies"
  local missing=() cmd
  local required=(rclone jq sha256sum)
  (( WITH_WATCHER )) && required+=(inotifywait)
  for cmd in "${required[@]}"; do
    if have "$cmd"; then
      info "$cmd: ok"
    else
      info "$cmd: MISSING"
      missing+=("$cmd")
    fi
  done
  (( ${#missing[@]} == 0 )) && return 0

  warn ""
  warn "Install these first. The package names, by distribution:"
  warn "  rclone       -> rclone"
  warn "  jq           -> jq"
  warn "  sha256sum    -> coreutils"
  warn "  inotifywait  -> inotify-tools"
  die "missing commands: ${missing[*]}"
}

# --- The rclone remote ------------------------------------------------------
# Nothing below works before this does, and the failure is much easier to read
# here than as an authentication error in a log file three hours from now. The
# remote checked is this profile's: two accounts are two remotes.
check_remote() {
  step "rclone remote '$REMOTE:'"
  if (( ! CHECK_REMOTE )); then
    info "skipped (--skip-remote-check)"
    return 0
  fi
  if rclone lsd "$REMOTE:" >/dev/null 2>&1; then
    info "responds, OAuth works"
    return 0
  fi
  warn "'rclone lsd $REMOTE:' failed."
  warn ""
  warn "Set the remote up first: rclone config"
  warn "Use your own OAuth client ID and the full 'drive' scope; see the README"
  warn "section 'Prerequisites'. Each account needs its own remote."
  warn "To install anyway: --skip-remote-check"
  die "the remote '$REMOTE:' does not answer"
}

# --- Symlinks ---------------------------------------------------------------
# Symlinks and not copies, on purpose: a copy stops being this repository the
# first time you pull.
link_scripts() {
  step "Scripts in $BIN_DIR"
  run mkdir -p "$BIN_DIR"
  local name target link current
  for name in "${SCRIPTS[@]}"; do
    if (( ! WITH_WATCHER )) && [[ "$name" == "gdrive-watch" ]]; then
      info "$name: skipped (--no-watcher)"
      continue
    fi
    target="$REPO_DIR/$name"
    link="$BIN_DIR/$name"
    if [[ -L "$link" ]]; then
      current="$(readlink -f "$link" 2>/dev/null)"
      if [[ "$current" == "$target" ]]; then
        info "$name: already linked here"
        continue
      fi
      info "$name: relinking (was -> ${current:-broken link})"
      run ln -sfn "$target" "$link"
    elif [[ -e "$link" ]]; then
      warn "$name: $link exists and is not a symlink — left untouched"
      continue
    else
      info "$name -> $target"
      run ln -s "$target" "$link"
    fi
  done

  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not in your PATH — add it to your shell profile" ;;
  esac
}

# --- Config files -----------------------------------------------------------
# An existing file is never overwritten. folders.txt in particular is the one
# file that is genuinely yours, and losing it means resolving every folder ID
# again.
install_configs() {
  local conf_dir="$CONF_ROOT/$PROFILE"
  step "Profile '$PROFILE' in $conf_dir"
  run mkdir -p "$conf_dir"
  local pair src dst mode fresh_config=0
  for pair in "folders.txt:644" "filter.txt:644" "config.env:600"; do
    src="$REPO_DIR/examples/${pair%%:*}"
    mode="${pair##*:}"
    dst="$conf_dir/${pair%%:*}"
    if [[ -e "$dst" ]]; then
      info "${pair%%:*}: exists, kept as it is"
    else
      info "${pair%%:*}: installed from examples/"
      run cp "$src" "$dst"
      run chmod "$mode" "$dst"
      [[ "${pair%%:*}" == "config.env" ]] && fresh_config=1
    fi
  done

  if (( fresh_config )); then
    info "remote: $REMOTE"
    info "local root: $LOCAL_ROOT"
    run write_profile_settings "$conf_dir/config.env"
  else
    info "remote and local root: as config.env already has them"
  fi
}

# Appended rather than templated in, so the comments in examples/config.env
# survive. %q because both values end up in a file that bash sources: a space
# in a local root must not become two words.
write_profile_settings() {
  local dst="$1"
  {
    printf '\n# Written by install.sh for profile %s.\n' "$PROFILE"
    printf 'GDRIVE_REMOTE=%q\n' "$REMOTE"
    printf 'GDRIVE_LOCAL=%q\n' "$LOCAL_ROOT"
  } >> "$dst"
}

# An active line is one that is neither blank nor a comment. Without one the
# timer would fire every 15 minutes and sync nothing, which looks identical to
# a broken install.
folders_configured() {
  local folders="$CONF_ROOT/$PROFILE/folders.txt"
  [[ -r "$folders" ]] || return 1
  grep -qEv '^[[:space:]]*(#|$)' "$folders"
}

# --- systemd ----------------------------------------------------------------
# The units are templates: one file installed once, instantiated per profile as
# gdrive-sync@work.service. Nothing per-profile is written into $UNIT_DIR.
install_templates() {
  step "systemd unit templates in $UNIT_DIR"
  have systemctl || { warn "systemctl not found — skipping the units"; return 0; }
  run mkdir -p "$UNIT_DIR"

  local units=("${TEMPLATES[@]}")
  (( WITH_WATCHER )) && units+=("$WATCH_TEMPLATE")
  local unit
  for unit in "${units[@]}"; do
    info "$unit"
    run cp "$REPO_DIR/systemd/$unit" "$UNIT_DIR/$unit"
  done
  run systemctl --user daemon-reload
}

enable_profile_units() {
  step "systemd instances for '$PROFILE'"
  have systemctl || { warn "systemctl not found — skipping the units"; return 0; }
  if [[ ! -e "$UNIT_DIR/gdrive-sync@.timer" ]]; then
    warn "the unit templates are not installed yet — run ./install.sh without"
    warn "--profile first, then this profile's timer can be enabled"
    return 0
  fi
  if [[ "$ENABLE_MODE" == "no" ]]; then
    info "not enabled (--no-enable)"
    return 0
  fi
  if ! folders_configured; then
    info "not enabled: $CONF_ROOT/$PROFILE/folders.txt has no folders in it yet"
    info "add your folders, then: systemctl --user enable --now gdrive-sync@$PROFILE.timer"
    return 0
  fi
  if [[ "$ENABLE_MODE" == "ask" ]] && ! confirm "Enable the timer (and the watcher) for '$PROFILE' now?"; then
    info "not enabled — enable later with systemctl --user enable --now gdrive-sync@$PROFILE.timer"
    return 0
  fi

  run systemctl --user enable --now "gdrive-sync@$PROFILE.timer"
  info "gdrive-sync@$PROFILE.timer enabled"
  if (( WITH_WATCHER )); then
    run systemctl --user enable --now "gdrive-watch@$PROFILE.service"
    info "gdrive-watch@$PROFILE.service enabled"
  fi
}

# --- Desktop entry ----------------------------------------------------------
install_desktop() {
  (( WITH_DESKTOP )) || return 0
  step "Desktop entry for .url shortcuts"
  run mkdir -p "$DESKTOP_DIR"
  run cp "$REPO_DIR/desktop/$DESKTOP_FILE" "$DESKTOP_DIR/$DESKTOP_FILE"
  info "$DESKTOP_FILE"
  have update-desktop-database && run update-desktop-database "$DESKTOP_DIR"
  if have xdg-mime; then
    run xdg-mime default "$DESKTOP_FILE" application/x-mswinurl
    info "application/x-mswinurl -> $DESKTOP_FILE"
  else
    warn "xdg-mime not found — .url files will not open on a double click"
  fi
}

# --- Omarchy widget ---------------------------------------------------------
# Advisory only: it changes nothing. The widget reads status.json, which is
# written by the first real sync run, and the installer deliberately does not
# perform one. Without this note a freshly installed widget looks broken.
check_widget() {
  local state_dir="$STATE_ROOT/$PROFILE"
  [[ -d "$OMARCHY_PLUGIN_DIR" ]] || return 0
  [[ -e "$state_dir/status.json" ]] && return 0
  step "Omarchy widget"
  info "the widget is installed at $OMARCHY_PLUGIN_DIR"
  info "but $state_dir/status.json does not exist yet, so it has"
  info "nothing to show for '$PROFILE'. The first gdrive-sync run writes it."
}

# --- Listing ----------------------------------------------------------------
timer_state() {
  local name="$1" out
  have systemctl || { printf 'unknown (no systemctl)\n'; return 0; }
  out="$(systemctl --user is-enabled "gdrive-sync@$name.timer" 2>/dev/null)"
  printf '%s\n' "${out:-unknown}"
}

do_list() {
  step "Profiles in $CONF_ROOT"
  local name found=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    found=1
    info "$name"
    info "    remote: $(profile_value "$name" remote):"
    info "    local:  $(profile_value "$name" local)"
    info "    timer:  $(timer_state "$name")"
  done < <(list_profiles)
  (( found )) && return 0
  info "none yet — create one:"
  info "  ./install.sh --profile=NAME --remote=REMOTE"
}

# --- Uninstall --------------------------------------------------------------
# Removes what the installer put there and nothing else. Synced files, the
# profile directories and the pinned IDs stay: they are yours, and a reinstall
# that had to resolve every folder ID again would be a worse outcome than a
# directory left behind.
#
# An enabled instance is a symlink systemctl wrote into a .wants directory, not
# a unit file of its own, which is why the targets are looked for in both
# places.
instance_targets() {
  local name="$1" unit path
  for unit in "gdrive-sync@$name.service" "gdrive-sync@$name.timer" "gdrive-watch@$name.service"; do
    for path in "$UNIT_DIR/$unit" "$UNIT_DIR"/*.wants/"$unit"; do
      [[ -e "$path" || -L "$path" ]] && printf '%s\n' "$path"
    done
  done
}

disable_instance() {
  local name="$1"
  have systemctl || return 0
  run systemctl --user disable --now "gdrive-sync@$name.timer"
  run systemctl --user disable --now "gdrive-watch@$name.service"
}

do_uninstall() {
  local targets=() profiles=() name link unit path

  if [[ -n "$PROFILE" ]]; then
    profile_valid "$PROFILE" || die "invalid profile name: $PROFILE"
    profiles=("$PROFILE")
  else
    mapfile -t profiles < <(list_profiles)
    for name in "${SCRIPTS[@]}"; do
      link="$BIN_DIR/$name"
      [[ -L "$link" && "$(readlink -f "$link" 2>/dev/null)" == "$REPO_DIR/$name" ]] && targets+=("$link")
    done
    for unit in "${TEMPLATES[@]}" "$WATCH_TEMPLATE"; do
      [[ -e "$UNIT_DIR/$unit" ]] && targets+=("$UNIT_DIR/$unit")
    done
    [[ -e "$DESKTOP_DIR/$DESKTOP_FILE" ]] && targets+=("$DESKTOP_DIR/$DESKTOP_FILE")
  fi

  for name in "${profiles[@]}"; do
    [[ -n "$name" ]] || continue
    while IFS= read -r path; do
      [[ -n "$path" ]] && targets+=("$path")
    done < <(instance_targets "$name")
  done

  step "Uninstall"
  if [[ -n "$PROFILE" ]]; then
    info "profile '$PROFILE' only: its units, not its configuration"
  fi
  if (( ${#targets[@]} == 0 )); then
    info "nothing installed from this clone was found"
    # Disabling is still worth doing: an instance can be enabled in systemd
    # without a .wants symlink this installer can see.
  else
    info "These will be removed:"
    printf '     %s\n' "${targets[@]}"
  fi
  info ""
  info "Kept: synced files, $CONF_ROOT, the state directory, rclone's config"
  if (( ! DRY_RUN )) && ! confirm "Remove them?"; then
    info "cancelled, nothing removed"
    return 0
  fi

  for name in "${profiles[@]}"; do
    [[ -n "$name" ]] && disable_instance "$name"
  done
  (( ${#targets[@]} )) && run rm -f "${targets[@]}"
  have systemctl && run systemctl --user daemon-reload
  if [[ -z "$PROFILE" ]]; then
    have update-desktop-database && run update-desktop-database "$DESKTOP_DIR"
  fi
  info "removed"
}

# --- Main -------------------------------------------------------------------
printf 'gdrive-sync installer %s\n' "$VERSION"
printf 'Repository: %s\n' "$REPO_DIR"
(( DRY_RUN )) && printf 'Dry run: nothing is changed.\n'

case "$ACTION" in
  uninstall) do_uninstall; exit 0 ;;
  list)      do_list; exit 0 ;;
esac

if [[ -z "$PROFILE" ]]; then
  # Machine phase: nothing here belongs to an account, so it runs once and asks
  # for no remote.
  check_deps
  link_scripts
  install_templates
  install_desktop

  step "Next"
  info "1. Create a profile, one per Google account:"
  info "     ./install.sh --profile=work --remote=GDriveWork"
  info "2. List them:  ./install.sh --list"
  info ""
  info "Each account needs its own rclone remote; see the README section"
  info "'Prerequisites'."
  printf '\n'
  exit 0
fi

profile_valid "$PROFILE" || {
  warn "A profile name is one path segment of [A-Za-z0-9._-], and is neither"
  warn "'.' nor '..': it becomes a directory name and a systemd instance name."
  die "invalid profile name: $PROFILE"
}

# An existing profile keeps what its config.env already says, because that file
# is never overwritten; the flags only supply what is not there yet.
[[ -z "$REMOTE" ]] && REMOTE="$(profile_value "$PROFILE" remote)"
[[ -z "$LOCAL_ROOT" ]] && LOCAL_ROOT="$(profile_value "$PROFILE" local)"

check_deps
check_local_collision
check_remote
install_configs
enable_profile_units
check_widget

step "Next"
if folders_configured; then
  info "1. Preview:  gdrive-sync --profile=$PROFILE -n"
  info "2. Run it:   gdrive-sync --profile=$PROFILE"
else
  info "1. Choose your folders:  \$EDITOR $CONF_ROOT/$PROFILE/folders.txt"
  info "2. Preview:              gdrive-sync --profile=$PROFILE -n"
  info "3. Run it:               gdrive-sync --profile=$PROFILE"
  info "4. Turn the timer on:    systemctl --user enable --now gdrive-sync@$PROFILE.timer"
fi
info ""
info "The first run merges both sides and keeps the newer copy of a file that"
info "exists in both. It deletes nothing. Deletions propagate from the second"
info "run on, in both directions — this is sync, not backup."
printf '\n'
