# AGENTS.md

Instructions for a coding agent working in this repository. Two jobs come up:
installing gdrive-sync on someone's machine, and changing its code. The rules
differ, so they are separate below.

This file is not a summary of the README. Read
[README.md](README.md) for what the tool does and why; read this for what you
are allowed to do while handling it.

---

## Job 1: installing it for a user

### Before anything else

**This is bidirectional sync, not backup.** A deletion is a change like any
other and propagates in both directions. Nothing you do here may be reasoned
about as "it only copies files".

Three rules, in order of how badly they go wrong:

1. **Never delete anything under the local root** (`~/GoogleDrive` by default)
   and never delete a line from `folders.txt` and then clean up the directory.
   The next run carries that deletion to Drive. If the user asks you to stop
   syncing a folder, remove the line and **leave the directory alone**; tell
   them it is now an ordinary local directory.
2. **Never run the first sync for them unattended.** `install.sh` deliberately
   does not, and neither should you. The first run is where a wrong folder or a
   wrong remote shows up, and it should show up on a screen someone is looking
   at. Run `gdrive-sync -n` (preview, changes nothing) and show the output; let
   the user start the real one, or run it only after they have read the preview
   and said yes.
3. **You cannot do the OAuth setup.** It needs a browser, a Google account and
   the Google API Console. Do not try to automate it, and do not paste
   credentials anywhere. Point the user at the README's *Prerequisites* section
   and wait. Everything below assumes `rclone lsd GoogleDrive:` already lists
   their Drive folders.

### The install

```bash
git clone https://github.com/mhavo/gdrive-sync.git ~/Work/gdrive-sync
cd ~/Work/gdrive-sync
./install.sh --dry-run      # read this out to the user first
./install.sh
```

`install.sh` does the whole installation and nothing else: dependency check,
remote check, symlinks into `~/.local/bin`, config files from `examples/`,
systemd units, the `.url` desktop entry. It runs no sync and touches no synced
data.

What it will not do, by design:

- **Install packages.** Missing dependencies are named and the script stops.
  Install them with the user's package manager, as a separate, visible step.
- **Overwrite a config file that exists.** `folders.txt` especially — it is the
  one genuinely irreplaceable file, and rewriting it means resolving every
  folder ID again.
- **Enable the timer while `folders.txt` is still empty.** A timer that fires
  every 15 minutes and syncs nothing looks exactly like a broken install.

Useful flags: `--no-watcher`, `--no-desktop`, `--no-enable`, `-y`,
`--skip-remote-check`, `--uninstall`. Full list: `./install.sh --help`.

In a non-interactive session the script cannot ask, so it does not enable
anything unless you pass `-y`. Pass `-y` only when the user has actually said
so.

### Choosing folders

The user edits `~/.config/rclone-gdrive-sync/folders.txt`, one Drive folder per
line, path from the root of Drive:

```
Documents
Projects/2026
```

Do not guess folder names from their Drive. If you need to see what is there:
`rclone lsd GoogleDrive:` — read-only, safe.

### Verifying, without syncing anything

```bash
gdrive-sync --status       # folders, pinned IDs, current name in Drive
gdrive-sync --list-paths   # the folder table; no network, no lock
gdrive-sync -n             # preview the rclone operations
./install.sh --dry-run     # what an install would change now
systemctl --user status gdrive-sync.timer gdrive-watch.service
journalctl --user -u gdrive-watch -n 50
```

All of these are safe to run unprompted. `gdrive-sync` with no flags is not.

### Uninstalling

```bash
./install.sh --uninstall
```

Removes the symlinks (only those pointing into this clone), the units and the
desktop entry. Keeps synced files, the config directory, the pinned IDs and
rclone's configuration. It lists what it will remove and asks first; `-y` skips
the question. **Do not then offer to delete the synced directory** unless the
user asks for it in those words — and if they do, make sure they know that a
later run of a reinstalled gdrive-sync would carry those deletions to Drive.

---

## Job 2: changing the code

### Layout

| Path | What |
|---|---|
| `gdrive-sync` | the sync: line parsing, ID resolution, safety gates, locking, bisync |
| `gdrive-watch` | inotify watcher; gets its folder table from `gdrive-sync --list-paths` |
| `open-url-shortcut` | opens a `.url` shortcut in a browser |
| `install.sh` | installer and uninstaller |
| `systemd/` | user units |
| `examples/` | the files `install.sh` copies into the config directory |
| `tests/` | the test suite and the command doubles it runs against |

### Conventions

- **Bash, `set -uo pipefail`.** Not `-e`: failures are handled where they
  happen, so one folder failing does not abandon the others.
- **`shellcheck -x` clean at the default level, informational findings
  included.** The test runner fails on a warning. Fix the code rather than
  adding a directive; if a directive is genuinely right, say why in a comment
  above it.
- **English everywhere** — code, comments, output, commit messages.
- **Comments explain why, not what.** The existing ones are the standard to
  match: they exist where a choice looks arbitrary and would otherwise be
  "simplified" away by the next reader.
- **No new runtime dependencies.** The current set is `rclone`, `jq`,
  `sha256sum` and `inotify-tools`, and each one is there because nothing in
  bash does that job.
- **Line parsing lives in `gdrive-sync` only.** `gdrive-watch` asks for a
  ready-made table with `--list-paths`. Do not add a second parser.

### Tests

```bash
tests/run-tests.sh
```

Must pass before any commit. It needs no network and no Drive account: the
scripts take their whole environment from variables, and `tests/fake-bin/`
holds a deterministic `rclone` double. `shellcheck`, `systemd-analyze` and the
inotify integration test are skipped when the tool is missing — a skip is not a
pass, so do not read "SKIPPED" as green when your change touches that area.

Rules for tests you add:

- **Never reach the real Drive or the user's rclone config.** If a test needs a
  new rclone subcommand, add it to `tests/fake-bin/rclone`. A test that shells
  out to the real `rclone` is a bug even when it passes.
- **Use the sandbox.** `make_sandbox` in `tests/lib.sh` redirects every path.
- **Use the hostile names.** `HOSTILE_NAMES` in `tests/lib.sh` covers spaces,
  non-ASCII, brackets and a slash. Folder names are user data from Google
  Drive; a change to name handling that is only tested against `Documents` is
  not tested.
- **Set per-run environment with the `INSTALL_ENV` array pattern**, not a
  `VAR=x some_function` prefix — in bash that assignment outlives the call and
  leaks into every test after it.

### Things that are the way they are on purpose

Change these only deliberately, and update the README's *Design notes* when you
do:

- **Folder IDs are pinned**, and the remote is addressed by ID, never by name.
  That is the central design decision; a rename in Drive must not break a sync.
- **Exit code 75** (`EX_TEMPFAIL`) means the lock was held. The timer treats it
  as success; `gdrive-watch` must be able to tell it apart from a real sync so
  it does not record a missed change as synced.
- **`--drive-export-formats url`** for Google Docs. An editable-looking export
  would be a lie about what round-trips.
- **`--resync-mode newer`** on an initialising run. A first run must not delete
  anything on either side.
- **`StartLimitIntervalSec=0`** on the watcher unit. The watcher exits 0 on
  purpose when `folders.txt` changes; systemd's default limit would leave it
  permanently failed after a few quick saves, silently watching nothing.
- **Symlinks, not copies**, into `~/.local/bin`. A copy stops being this
  repository the first time the user pulls.
