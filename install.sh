#!/usr/bin/env bash
# Installs gdrive-sync from this clone: symlinks on PATH, config files, systemd
# units and the .url desktop entry.
#
# The script installs, it does not sync. It never runs bisync, never touches
# ~/GoogleDrive and never overwrites a config file you already have. The first
# sync stays a thing you start yourself, because that is the run where you want
# to be looking at the output.
#
# Everything it does is undone by --uninstall, and shown without doing it by
# --dry-run.
set -uo pipefail

VERSION="0.1.0"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Settings ---------------------------------------------------------------
# The same config file gdrive-sync reads, for one reason only: the remote name,
# so the check below tests the remote you actually use. The install paths are
# separate variables, because they are the installer's business, not the
# sync's.
CONF_DIR="${GDRIVE_CONF_DIR:-$HOME/.config/rclone-gdrive-sync}"
CONFIG_FILE="$CONF_DIR/config.env"
# shellcheck source=/dev/null
[[ -r "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

REMOTE="${GDRIVE_REMOTE:-GoogleDrive}"
REMOTE="${REMOTE%:}"
FOLDERS="${GDRIVE_FOLDERS:-$CONF_DIR/folders.txt}"
STATE_DIR="${GDRIVE_STATE_DIR:-$HOME/.local/state/rclone-gdrive-sync}"

# The Omarchy bar widget is distributed as a plugin, which omarchy clones into
# its own plugins directory. The installer neither installs nor removes it; it
# only looks, so it can say why the widget has nothing to show yet.
OMARCHY_PLUGIN_DIR="${GDRIVE_OMARCHY_PLUGIN_DIR:-$HOME/.config/omarchy/plugins/mhavo.gdrive-sync}"

BIN_DIR="${GDRIVE_BIN_DIR:-$HOME/.local/bin}"
UNIT_DIR="${GDRIVE_UNIT_DIR:-$HOME/.config/systemd/user}"
DESKTOP_DIR="${GDRIVE_DESKTOP_DIR:-$HOME/.local/share/applications}"

SCRIPTS=(gdrive-sync gdrive-watch open-url-shortcut)
DESKTOP_FILE="url-shortcut.desktop"

ACTION="install"
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
    --no-watcher)       WITH_WATCHER=0 ;;
    --no-desktop)       WITH_DESKTOP=0 ;;
    --skip-remote-check) CHECK_REMOTE=0 ;;
    --no-enable)        ENABLE_MODE="no" ;;
    -y|--yes)           ASSUME_YES=1; [[ "$ENABLE_MODE" == "ask" ]] && ENABLE_MODE="yes" ;;
    -h|--help)
      cat <<HELP
install.sh [options]

Installs gdrive-sync from this clone. Syncs nothing; the first run stays yours.

  -n, --dry-run     Print every step without performing any of it
      --uninstall   Remove what was installed. Keeps synced data, config and
                      state; lists what it will remove and asks first
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
  GDRIVE_CONF_DIR     $CONF_DIR
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
# here than as an authentication error in a log file three hours from now.
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
  warn "section 'Prerequisites'. To install anyway: --skip-remote-check"
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
  step "Config in $CONF_DIR"
  run mkdir -p "$CONF_DIR"
  local pair src dst mode
  for pair in "folders.txt:644" "filter.txt:644" "config.env:600"; do
    src="$REPO_DIR/examples/${pair%%:*}"
    mode="${pair##*:}"
    dst="$CONF_DIR/${pair%%:*}"
    if [[ -e "$dst" ]]; then
      info "${pair%%:*}: exists, kept as it is"
    else
      info "${pair%%:*}: installed from examples/"
      run cp "$src" "$dst"
      run chmod "$mode" "$dst"
    fi
  done
}

# An active line is one that is neither blank nor a comment. Without one the
# timer would fire every 15 minutes and sync nothing, which looks identical to
# a broken install.
folders_configured() {
  [[ -r "$FOLDERS" ]] || return 1
  grep -qEv '^[[:space:]]*(#|$)' "$FOLDERS"
}

# --- systemd ----------------------------------------------------------------
install_units() {
  step "systemd units in $UNIT_DIR"
  have systemctl || { warn "systemctl not found — skipping the units"; return 0; }
  run mkdir -p "$UNIT_DIR"

  local units=(gdrive-sync.service gdrive-sync.timer)
  (( WITH_WATCHER )) && units+=(gdrive-watch.service)
  local unit
  for unit in "${units[@]}"; do
    info "$unit"
    run cp "$REPO_DIR/systemd/$unit" "$UNIT_DIR/$unit"
  done
  run systemctl --user daemon-reload

  if [[ "$ENABLE_MODE" == "no" ]]; then
    info "not enabled (--no-enable)"
    return 0
  fi
  if ! folders_configured; then
    info "not enabled: $FOLDERS has no folders in it yet"
    info "add your folders, then: systemctl --user enable --now gdrive-sync.timer"
    return 0
  fi
  if [[ "$ENABLE_MODE" == "ask" ]] && ! confirm "Enable the timer (and the watcher) now?"; then
    info "not enabled — enable later with systemctl --user enable --now gdrive-sync.timer"
    return 0
  fi

  run systemctl --user enable --now gdrive-sync.timer
  info "gdrive-sync.timer enabled"
  if (( WITH_WATCHER )); then
    run systemctl --user enable --now gdrive-watch.service
    info "gdrive-watch.service enabled"
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
  [[ -d "$OMARCHY_PLUGIN_DIR" ]] || return 0
  [[ -e "$STATE_DIR/status.json" ]] && return 0
  step "Omarchy widget"
  info "the widget is installed at $OMARCHY_PLUGIN_DIR"
  info "but $STATE_DIR/status.json does not exist yet, so it has"
  info "nothing to show. The first gdrive-sync run writes it."
}

# --- Uninstall --------------------------------------------------------------
# Removes what the installer put there and nothing else. Synced files, the
# config directory and the pinned IDs stay: they are yours, and a reinstall
# that had to resolve every folder ID again would be a worse outcome than a
# directory left behind.
do_uninstall() {
  local targets=() name link unit
  for name in "${SCRIPTS[@]}"; do
    link="$BIN_DIR/$name"
    [[ -L "$link" && "$(readlink -f "$link" 2>/dev/null)" == "$REPO_DIR/$name" ]] && targets+=("$link")
  done
  for unit in gdrive-sync.service gdrive-sync.timer gdrive-watch.service; do
    [[ -e "$UNIT_DIR/$unit" ]] && targets+=("$UNIT_DIR/$unit")
  done
  [[ -e "$DESKTOP_DIR/$DESKTOP_FILE" ]] && targets+=("$DESKTOP_DIR/$DESKTOP_FILE")

  step "Uninstall"
  if (( ${#targets[@]} == 0 )); then
    info "nothing installed from this clone was found"
    return 0
  fi
  info "These will be removed:"
  printf '     %s\n' "${targets[@]}"
  info ""
  info "Kept: synced files, $CONF_DIR, the state directory, rclone's config"
  if (( ! DRY_RUN )) && ! confirm "Remove them?"; then
    info "cancelled, nothing removed"
    return 0
  fi

  if have systemctl; then
    run systemctl --user disable --now gdrive-sync.timer
    run systemctl --user disable --now gdrive-watch.service
  fi
  run rm -f "${targets[@]}"
  have systemctl && run systemctl --user daemon-reload
  have update-desktop-database && run update-desktop-database "$DESKTOP_DIR"
  info "removed"
}

# --- Main -------------------------------------------------------------------
printf 'gdrive-sync installer %s\n' "$VERSION"
printf 'Repository: %s\n' "$REPO_DIR"
(( DRY_RUN )) && printf 'Dry run: nothing is changed.\n'

if [[ "$ACTION" == "uninstall" ]]; then
  do_uninstall
  exit 0
fi

check_deps
check_remote
link_scripts
install_configs
install_units
install_desktop
check_widget

step "Next"
if folders_configured; then
  info "1. Preview:  gdrive-sync -n"
  info "2. Run it:   gdrive-sync"
else
  info "1. Choose your folders:  \$EDITOR $FOLDERS"
  info "2. Preview:              gdrive-sync -n"
  info "3. Run it:               gdrive-sync"
  info "4. Turn the timer on:    systemctl --user enable --now gdrive-sync.timer"
fi
info ""
info "The first run merges both sides and keeps the newer copy of a file that"
info "exists in both. It deletes nothing. Deletions propagate from the second"
info "run on, in both directions — this is sync, not backup."
printf '\n'
