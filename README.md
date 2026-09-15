# gdrive-sync

Keeps selected Google Drive folders and a directory on your machine
(`~/GoogleDrive`) identical. A change on either side travels to the other on
the next run. Underneath is `rclone bisync`; on top is a small bash script that
handles folder selection, initialisation and safety checks.

Not all of Drive is synced. Folders are picked one at a time in a list file.

## Why this and not X

Several tools put Google Drive on a Linux machine, and they solve different
problems. Pick by what you actually need:

| | What it gives you | Where it falls short |
|---|---|---|
| **gdrive-sync** (this) | Real files on disk, works offline, selected folders only, bidirectional | You store a local copy; Google Docs are shortcuts, not editable files |
| [linux-gdrive-sync](https://github.com/namastexlabs/linux-gdrive-sync) | The closest sibling: the same `rclone bisync` + inotify shape. An installer that also installs the dependencies for you, a `status.json` for monitoring, automatic recovery | Syncs one directory — the whole remote — not selected folders. Addresses Drive by path, so a rename breaks the run. A daily 3 am `--resync` and an automatic one after six failures both throw away bisync's state, and a bare `--resync` means `--resync-mode path1`: with Drive as Path1, its copy silently wins any file that changed on both sides. Google Docs arrive as editable-looking exports. No tests |
| [google-drive-ocamlfuse](https://github.com/astrada/google-drive-ocamlfuse) | Mounts all of Drive as a filesystem, no disk space used, mature and actively maintained | No sync engine: files live on the network behind a metadata cache. Offline access is not a design goal, and Google Docs are read-only exports |
| Plain [`rclone bisync`](https://rclone.org/bisync/) | The whole sync engine — this project is a wrapper around it | You wire up folder selection, scheduling, and the rename hazard below yourself |
| GNOME Online Accounts / KIO GDrive | Zero setup inside their desktop | A virtual filesystem, not sync; poor behaviour with large files and non-GNOME/KDE apps |
| Insync | Full bidirectional sync with a GUI | Commercial, closed source |

Short version: if you want to edit files on a plane, a FUSE mount is the wrong
tool. If you want to browse 500 GB without spending 500 GB of disk, this is the
wrong tool. If you want the whole of Drive in one directory and an installer
that runs your package manager too, linux-gdrive-sync gets you there in one
command.
This project is for the case where you sync a few named folders rather than
everything, and where nothing may overwrite a local edit without being asked.

One thing is not a point of difference: every option above except the desktop
integrations needs its own Google OAuth client set up by hand. That is Google's
doing, not any one tool's — see
[Prerequisites](#prerequisites-the-rclone-remote-and-oauth).

## This is not a backup

In bidirectional sync a deletion is a change like any other, and it propagates
both ways. Delete a file on your machine and it goes from Drive too. Deletions
land in Drive's trash and are recoverable for 30 days, but that is an undo
window, not a backup.

## How it works

**You write the folder name; the machine uses the folder ID.**

You write names in the list, because names are what humans can keep track of:

```
Documents
Projects/2026
```

On the first run the script asks Drive for the ID of the folder with that name
and records the ID. From then on syncing never uses the name again, only the ID.

This matters for one reason. `rclone bisync` addresses the remote side by path.
Rename the folder in Drive and that path no longer resolves — the run fails, or
worse, resolves to something else you happen to have created under the old
name. Bisync has its own guards against the destructive version of this (see
below), but a guard that aborts the run still leaves you with a broken sync and
an error that does not say *why*. A pinned ID does not change when the name
does, so there is nothing to break and nothing to diagnose.

**What bisync already protects you from.** Worth being precise about, because
these are not this script's doing:

- An empty listing on either side is a critical failure in bisync itself:
  *"Empty current PathN listing. Cannot sync to an empty directory."*
- `--max-delete` aborts the run if more than 50% of files on one side would be
  deleted (that is the default; `--force` overrides it).
- `--conflict-resolve newer` picks a winner when a file changed on both sides,
  and keeps the loser rather than discarding it.

**What this script adds on top.** Before every run it checks two things: does
the folder still resolve by ID, and if it does, is it empty while the local side
is not. Either failure skips that folder and runs no sync for it. The point is
not that bisync would otherwise delete your files — it would abort — but that
you get a named reason ("ID does not resolve in Drive", "remote folder is empty
but local is not") for the one folder affected, while the others keep syncing.

**The machine runs the sync by itself** every 15 minutes on a systemd timer. The
interval is measured from the end of the previous run, so a long run does not
queue up more.

**Optionally, a watcher** (`gdrive-watch`) listens for local changes with
inotify and syncs the folder that actually changed within seconds. rclone
[states outright](https://rclone.org/bisync/) that it has no built-in ability to
watch the local filesystem and must be run blindly on a schedule; this fills
that in. Drive's side cannot be watched this way, so the 15-minute timer stays
as it is and doubles as the safety net whenever the watcher is down or has
missed an event.

## Prerequisites: the rclone remote and OAuth

This project does no authentication of its own. It assumes an already working
rclone remote and calls `rclone` with it; every credential lives in
`~/.config/rclone/rclone.conf` and is rclone's business, not this script's.

Setting that remote up is the one genuinely fiddly part of the whole
installation, and three things about it are easy to get wrong. Read
[rclone's Google Drive documentation](https://rclone.org/drive/) — the summary
below is orientation, not a substitute.

**1. You need your own OAuth client ID.** rclone ships with a shared one, and
the documentation now states plainly: *"This shared client_id is being retired
and will stop working during 2026."* Create your own in the
[Google API Console](https://console.cloud.google.com/) — new project, enable
the Google Drive API, configure the OAuth consent screen, create an OAuth
client of type *Desktop app* — and give the ID and secret to `rclone config`.
Rclone's [Making your own client_id](https://rclone.org/drive/#making-your-own-client-id)
has the click-by-click steps. A private client ID also gets you your own share
of Google's rate limit (roughly 10 transactions per second per client ID)
rather than a slice of everyone else's.

**2. Publish the consent screen, or your sync dies every seven days.** If the
OAuth app is left in *Testing* status, Google expires the grant after a week.
For this project that failure is quiet and annoying: the timer keeps firing,
every run fails on authentication, and nothing is syncing until you notice.
Publishing the app avoids the weekly expiry; for personal use under 100 users
it needs no formal verification, you just accept the "Google hasn't verified
this app" warning once during sign-in.

**3. Use the `drive` scope, not `drive.file`.** `drive.file` grants access only
to files rclone itself created, so a folder that already exists in your Drive
would look empty — which is exactly the situation the safety gate refuses to
sync. The default full `drive` scope is the one you want.

Once `rclone config` is done, check that the remote works before going any
further:

```bash
rclone lsd GoogleDrive:
```

That must list your Drive folders. If it does not, fix it here — nothing below
will work until it does.

**On a headless machine** there is no browser for the OAuth redirect. Either run
`rclone authorize` on a machine that has one and paste the token back, or
forward the port rclone listens on:

```bash
ssh -L localhost:53682:localhost:53682 user@server
```

See [rclone's remote setup guide](https://rclone.org/remote_setup/).

## Installation

Beyond a working remote you need `rclone`, `jq`, and `sha256sum` (GNU coreutils),
plus `inotify-tools` for the watcher. The remote is assumed to be named
`GoogleDrive:`; a different name and other paths are available through a config
file, see [Configuration](#configuration).

```bash
git clone https://github.com/mhavo/gdrive-sync.git ~/Work/gdrive-sync
cd ~/Work/gdrive-sync

./install.sh --dry-run    # every step, performed none of them
./install.sh
```

`install.sh` checks the dependencies, checks that the remote answers, links the
scripts into `~/.local/bin`, copies the config files out of `examples/`,
installs the systemd units and registers the `.url` desktop entry.

It syncs nothing. The first run stays yours, because that is the run where a
wrong folder or a wrong remote shows up and you want to be looking at it:

```bash
$EDITOR ~/.config/rclone-gdrive-sync/folders.txt   # add your folders
gdrive-sync -n     # previews rclone operations; changes no synced data or wrapper state
gdrive-sync
```

Three things the installer will not do. It does not run your package manager —
missing commands are named and it stops, because installing packages as root is
not what you asked for. It does not overwrite a config file that already exists,
`folders.txt` least of all. And it does not enable the timer while `folders.txt`
is still empty, because a timer that fires every 15 minutes and syncs nothing
looks exactly like a broken install.

Flags: `--no-watcher`, `--no-desktop`, `--no-enable`, `-y`,
`--skip-remote-check`, `--uninstall`. See `./install.sh --help`.

`./install.sh --uninstall` removes the symlinks, the units and the desktop
entry, and keeps your synced files, your config and the pinned IDs.

<details>
<summary><b>By hand</b>, if you would rather see every step</summary>

```bash
# Scripts on PATH as symlinks, not copies — a copy drifts over time
ln -s ~/Work/gdrive-sync/gdrive-sync        ~/.local/bin/gdrive-sync
ln -s ~/Work/gdrive-sync/gdrive-watch       ~/.local/bin/gdrive-watch
ln -s ~/Work/gdrive-sync/open-url-shortcut  ~/.local/bin/open-url-shortcut

# Folder list and filters
mkdir -p ~/.config/rclone-gdrive-sync
cp examples/folders.txt examples/filter.txt ~/.config/rclone-gdrive-sync/
$EDITOR ~/.config/rclone-gdrive-sync/folders.txt   # add your folders

# Optional: change the remote name and paths (see Configuration)
cp examples/config.env ~/.config/rclone-gdrive-sync/
chmod 600 ~/.config/rclone-gdrive-sync/config.env

# First run by hand, so you see what happens
gdrive-sync -n
gdrive-sync

# Timer on
cp systemd/gdrive-sync.* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now gdrive-sync.timer

# Optional: watcher for instant local-to-Drive sync
cp systemd/gdrive-watch.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now gdrive-watch.service

# For opening Google Docs files (see below)
cp desktop/url-shortcut.desktop ~/.local/share/applications/
update-desktop-database ~/.local/share/applications
xdg-mime default url-shortcut.desktop application/x-mswinurl
```

</details>

**Installing this with an AI agent?** [AGENTS.md](AGENTS.md) is written for
exactly that: what is safe to run unprompted, what must not be automated, and
why deleting a local directory here is not a local operation.

## Configuration

Without a config file the defaults apply: remote `GoogleDrive:`, local root
`~/GoogleDrive`, config in `~/.config/rclone-gdrive-sync/` and state in
`~/.local/state/rclone-gdrive-sync/`. That is usually enough.

To change something, copy `examples/config.env` into the config directory and
uncomment the lines you want:

| Variable | Default | What |
|---|---|---|
| `GDRIVE_REMOTE` | `GoogleDrive` | rclone remote name (`rclone config`) |
| `GDRIVE_LOCAL` | `$HOME/GoogleDrive` | local root directory |
| `GDRIVE_STATE_DIR` | `$HOME/.local/state/rclone-gdrive-sync` | pinned IDs, logs, lock |
| `GDRIVE_CONF_DIR` | `$HOME/.config/rclone-gdrive-sync` | config directory (environment only — it is read before the config file) |
| `GDRIVE_FOLDERS` | `$GDRIVE_CONF_DIR/folders.txt` | folder list |
| `GDRIVE_FILTER` | `$GDRIVE_CONF_DIR/filter.txt` | rclone filter file |
| `GDRIVE_DEBOUNCE_SEC` | `5` | watcher: how long changes must be quiet before syncing |
| `GDRIVE_RETRY_SEC` | `30` | watcher: retry interval when the previous run held the lock |
| `GDRIVE_SYNC_BIN` | `gdrive-sync` | watcher: which gdrive-sync to run |

The config file is sourced as bash, so keep it to variable assignments and keep
its permissions to yourself (`chmod 600`).

## Seeing what is going on

`--status` is the command that shows you where things stand:

```
Documents
  local     : /home/user/GoogleDrive/Documents
  ID        : 0BwyG7PLuwLCCWTR0UWJVc2kzQ0k (pinned 2026-09-15T12:18:09+03:00)
  in Drive  : renamed: Documents 2026
```

## Adding and removing a folder

**Adding:** write a line into
`~/.config/rclone-gdrive-sync/folders.txt`. The next run does the rest: resolves
the ID, creates the local directory and performs the first initialising run. It
deletes nothing on either side — it merges both and keeps the newer version when
the same file exists in both.

You can also give the ID directly, in which case the second column is the name
of the local directory:

```
id:1Ry8oqCD5s-CG4j2Cbypr6EEZfiRZHXsZ  Archive
```

The `id:` prefix is mandatory. An ID is never guessed from the look of a line,
because a folder may well be named `Imageprocessingtrainingmaterials2007`.

**Removing:** delete the line from the list. The local directory and the
recorded ID stay; you can remove them by hand. **Do not delete local content
before the line is gone from the list** — otherwise the next run carries the
deletion to Drive.

## Google Docs documents

Google Docs, Sheets and Slides are not files in Drive but references. What
arrives on your machine is a 127-byte `.url` shortcut that opens the document in
a browser. This is deliberate: exported to Word format the file would look
editable, but edits would never make it back into the document.

Linux file managers cannot open a `.url` file on their own, so `open-url-shortcut`
and its `.desktop` entry are included (see installation).

**Warning:** to sync, the shortcut is an ordinary file. Delete it locally and
the deletion takes the actual Google document with it. That goes to Drive's
trash and is not lost permanently.

## When something goes wrong

| Situation | What to do |
|---|---|
| Folder renamed in Drive | Nothing, syncing continues. `--status` shows the new name. |
| `ID does not resolve in Drive` | The folder was deleted or permissions changed. Check Drive. If it really is a different folder now: `--repin=Folder` |
| `remote folder is empty but local is not` | Look in Drive's trash before doing anything else. If you emptied it yourself: `--allow-empty-remote` |
| One folder got confused | `gdrive-sync --resync --only=Folder` |
| You deleted a file by accident | Drive's trash, 30 days. Listing: `rclone lsjson GoogleDrive: --drive-trashed-only -R --files-only` |
| The same file changed on both sides | The newer one wins, the older is kept alongside it as `file.conflict1`. Nothing is lost. |
| Everything stopped syncing after about a week | The OAuth consent screen is in *Testing* status and the grant expired. Publish the app in the Google API Console, then `rclone config reconnect GoogleDrive:` |
| `failed to get token` / auth errors in the log | Check the remote itself first: `rclone lsd GoogleDrive:` |
| Timer off | `systemctl --user disable --now gdrive-sync.timer` — running by hand still works |
| Watcher off | `systemctl --user disable --now gdrive-watch.service` — the timer keeps syncing |
| You want to see what happened | `~/.local/state/rclone-gdrive-sync/logs/`, one file per day, cleaned up after 30 days. The watcher logs to the journal: `journalctl --user -u gdrive-watch` |

## What lives where

| Path | What |
|---|---|
| `~/.config/rclone-gdrive-sync/folders.txt` | folder list, the file you edit |
| `~/.config/rclone-gdrive-sync/config.env` | settings: remote name and paths (optional) |
| `~/.config/rclone-gdrive-sync/filter.txt` | junk files to skip (`.DS_Store`, `Thumbs.db`, lock files) |
| `~/GoogleDrive/` | synced content |
| `~/.local/state/rclone-gdrive-sync/initialized/` | recorded folder IDs |
| `~/.local/state/rclone-gdrive-sync/logs/` | logs |
| `~/.cache/rclone/bisync/` | rclone's comparison listings, built by `--resync` |

## Design notes

Reasons for individual choices, in case they look arbitrary:

- **`--drive-export-formats url`** — see the Google Docs section above. Any
  editable export format would be a lie about what round-trips.
- **`--resync-mode newer`** on the initialising run — a first run must not
  delete anything on either side, so it merges and lets the newer copy win.
  A wrong clock is a smaller problem than a deleted file.
- **`OnUnitInactiveSec=15min` rather than `OnCalendar`** — the interval is
  measured from the end of the previous run. With `OnCalendar` a sync that takes
  longer than the interval would have the next one queued behind it.
- **`--compare size,modtime` with `--modify-window 1s`** — Drive's timestamps
  have limited resolution, and checksums on every run would cost a full read.
- **Exit code 75** (`EX_TEMPFAIL`) when the lock is held — the timer treats it
  as success (`SuccessExitStatus=75`), while `gdrive-watch` needs to tell it
  apart from a real sync so it does not record a missed change as synced.
- **`StartLimitIntervalSec=0`** on the watcher unit — the watcher exits 0 on
  purpose when `folders.txt` changes, so systemd re-reads the folder table.
  systemd's default limit (5 starts in 10 seconds) would leave the unit
  permanently failed after a few quick saves. Silently watching nothing is the
  one failure mode this must not produce.

## Tests

```bash
tests/run-tests.sh
```

No network and no Drive account needed: `gdrive-sync` takes its whole
environment from variables, so the tests run in a sandbox — `install.sh`
included, against a fake `rclone` and a sandboxed set of install paths.
`shellcheck` and the inotify integration test are skipped if the tools are
missing.

## Licence

MIT, see [LICENSE](LICENSE).
