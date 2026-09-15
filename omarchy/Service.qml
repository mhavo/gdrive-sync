import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Everything the widget knows about gdrive-sync, and the only place that talks
// to the outside world.
//
// Three sources, in descending order of chattiness:
//   - status.json and watcher.json, watched with FileView. One writer per
//     file, each replacing it atomically, so a reader never sees half a write
//     and no polling is needed.
//   - folders.txt and config.env, watched the same way: they say whether the
//     tool is configured at all and where the local root lives.
//   - `systemctl --user is-active` and a PATH probe, polled rarely, because
//     unit state and an installed binary change about as often as the user
//     reinstalls something.
//
// No rclone, no gdrive-sync, no subprocess per refresh: omarchy-shell is a
// long-lived process shared with the rest of the desktop and must never wait
// on this widget.
Item {
  id: root
  visible: false

  property var settings: ({})
  property string pluginDir: ""

  // --- derived state ---------------------------------------------------------

  property var status: null          // parsed status.json, or null
  property var watcher: null         // parsed watcher.json, or null
  property string foldersText: ""
  property string configText: ""

  // True until the PATH probe answers. Assuming the tool is present avoids a
  // flash of "not set up" every time the shell starts or reloads plugins.
  property bool installed: true
  property bool probed: false

  // Null means "not asked yet", which deriveState treats as unknown rather
  // than as an inactive timer.
  property var timerActive: null

  property double now: Date.now()

  readonly property int staleAfterMin: intSetting("staleAfterMin", Model.DEFAULT_STALE_AFTER_MIN, 5, 1440)
  // The base of the stuck threshold. Model.deriveState adds a minute per
  // folder from status.json and caps the total at the unit's TimeoutStartSec.
  readonly property int stuckAfterMin: intSetting("stuckAfterMin", Model.DEFAULT_STUCK_AFTER_MIN, 5, 240)

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string confDir: Quickshell.env("GDRIVE_CONF_DIR") || Model.defaultConfDir(home)
  // folders.txt and filter.txt can be moved with GDRIVE_FOLDERS / GDRIVE_FILTER,
  // from the environment or from config.env itself, so the buttons that open
  // them must resolve the same way gdrive-sync does. config.env has no such
  // override: it is read before the file that could contain one.
  readonly property string foldersPath: Quickshell.env("GDRIVE_FOLDERS")
    || Model.envValue(configText, "GDRIVE_FOLDERS", Model.joinPath(confDir, "folders.txt"), home)
  readonly property string filterPath: Quickshell.env("GDRIVE_FILTER")
    || Model.envValue(configText, "GDRIVE_FILTER", Model.joinPath(confDir, "filter.txt"), home)
  readonly property string configPath: Model.joinPath(confDir, "config.env")

  // config.env is optional. The button that opens it appears only once the file
  // exists: an editor invoked on a missing path would create it on save with
  // the default umask and without the comments in examples/config.env, while
  // install.sh copies the example and sets the permissions to 600.
  readonly property bool configExists: configFile.ok
  readonly property string stateDir: Quickshell.env("GDRIVE_STATE_DIR")
    || Model.envValue(configText, "GDRIVE_STATE_DIR", Model.defaultStateDir(home), home)
  readonly property string statusPath: Model.joinPath(stateDir, "status.json")
  readonly property string watcherPath: Model.joinPath(stateDir, "watcher.json")
  readonly property string localRoot: Quickshell.env("GDRIVE_LOCAL")
    || Model.envValue(configText, "GDRIVE_LOCAL", Model.defaultLocalRoot(home), home)

  readonly property var folderList: Model.folderSpecs(foldersText)
  readonly property var derived: Model.deriveState({
    now: root.now,
    status: root.status,
    installed: root.installed,
    folderCount: root.folderList.length,
    timerActive: root.timerActive,
    staleAfterMin: root.staleAfterMin,
    stuckAfterMin: root.stuckAfterMin
  })
  readonly property string syncState: derived.state
  readonly property string detail: derived.detail
  readonly property bool unconfigured: syncState === "unconfigured"
  readonly property bool syncing: syncState === "syncing"

  readonly property var header: Model.headerSummary(status, now)
  readonly property var folderRows: Model.folderRows(status)
  readonly property string folderSummary: Model.folderSummary(status)
  readonly property var watcherRow: Model.watcherRow(watcher, now)

  // --- settings --------------------------------------------------------------

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  // --- actions ---------------------------------------------------------------
  //
  // Every action is a string handed to the caller, which passes it to
  // bar.run(). Nothing here starts a process itself.

  function syncNowCommand() { return Model.syncNowCommand() }
  function openFolderCommand() { return Model.openPathCommand(localRoot) }
  // There is no log file: both units log to the journal under their own
  // identifiers, so the action follows the journal instead of opening a path.
  function openLogCommand() { return Model.journalCommand() }
  function installCommand() { return Model.installCommand(pluginDir) }
  function editFoldersCommand() { return Model.editFoldersCommand(foldersPath) }
  function editFilterCommand() { return Model.openTextCommand(filterPath) }
  function editConfigCommand() { return configExists ? Model.openTextCommand(configPath) : "" }

  // Called when the popup opens and on the slow tick. Re-reads the rarely
  // changing sources and retries any file that was not there last time.
  function refresh() {
    root.now = Date.now()
    probeProcess.running = true
    timerProcess.running = true
    if (!statusFile.ok) statusFile.reload()
    if (!watcherFile.ok) watcherFile.reload()
    if (!foldersFile.ok) foldersFile.reload()
    if (!configFile.ok) configFile.reload()
  }

  // --- files -----------------------------------------------------------------
  //
  // FileView cannot watch a file that does not exist yet, so each of these
  // tracks whether it loaded and the retry timer below asks again. A missing
  // status.json is a normal state — nothing has run — and never an error.

  FileView {
    id: statusFile
    property bool ok: false
    path: root.statusPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      statusFile.ok = true
      root.status = Model.parseJson(text())
      root.now = Date.now()
    }
    onLoadFailed: {
      statusFile.ok = false
      root.status = null
    }
  }

  FileView {
    id: watcherFile
    property bool ok: false
    path: root.watcherPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      watcherFile.ok = true
      root.watcher = Model.parseJson(text())
      root.now = Date.now()
    }
    onLoadFailed: {
      watcherFile.ok = false
      root.watcher = null
    }
  }

  FileView {
    id: foldersFile
    property bool ok: false
    path: root.foldersPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      foldersFile.ok = true
      root.foldersText = String(text() || "")
    }
    onLoadFailed: {
      foldersFile.ok = false
      root.foldersText = ""
    }
  }

  FileView {
    id: configFile
    property bool ok: false
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      configFile.ok = true
      root.configText = String(text() || "")
    }
    onLoadFailed: {
      // config.env is optional: without it the defaults apply.
      configFile.ok = false
      root.configText = ""
    }
  }

  // --- rarely polled sources -------------------------------------------------

  // A login shell, because install.sh puts gdrive-sync in ~/.local/bin, which
  // omarchy-shell's own PATH need not carry.
  Process {
    id: probeProcess
    command: ["bash", "-lc", "command -v gdrive-sync >/dev/null 2>&1"]
    onExited: function(exitCode) {
      root.installed = exitCode === 0
      root.probed = true
    }
  }

  Process {
    id: timerProcess
    command: ["systemctl", "--user", "is-active", "gdrive-sync.timer"]
    stdout: StdioCollector {
      waitForEnd: true
      // `is-active` exits non-zero for every state but active, so the word it
      // prints is the answer and the exit code adds nothing.
      onStreamFinished: root.timerActive = Model.timerActiveFromOutput(text)
    }
  }

  // One tick covers three jobs at once: re-probe the slow sources, notice a
  // file that has appeared since, and move the clock that "3 min ago" and the
  // stale threshold are measured against.
  Timer {
    interval: 60000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
