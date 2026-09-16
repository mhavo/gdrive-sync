import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// One profile: its four files, its paths, and the state derived from them.
//
// Everything here used to be Service.qml itself. It moved because the bar icon
// has to speak for every account at once, and a state object that can only ever
// describe one of them cannot do that. Service.qml now owns one of these per
// profile and the slow, shared sources — the PATH probe, the clock, the timer
// query — stay up there, so adding an account costs four FileViews and not a
// single extra process.
Item {
  id: profileState
  visible: false

  // The profile this object describes. Everything below is derived from it, so
  // it is set once by the Instantiator and never changes for a given instance.
  required property string profile

  property string home: ""
  property double now: Date.now()
  property bool installed: true
  // Null means "not asked yet", which deriveState treats as unknown rather
  // than as an inactive timer.
  property var timerActive: null
  property int staleAfterMin: Model.DEFAULT_STALE_AFTER_MIN
  property int stuckAfterMin: Model.DEFAULT_STUCK_AFTER_MIN

  // --- paths -----------------------------------------------------------------
  //
  // The environment overrides apply to the roots, not to a directory: with
  // several profiles a variable naming one config directory could only ever
  // name the wrong one. The profile is appended to whatever root resolves.
  readonly property string confRoot: Quickshell.env("GDRIVE_CONF_ROOT") || ""
  readonly property string stateRootOverride: Quickshell.env("GDRIVE_STATE_ROOT") || ""
  readonly property string confDir: confRoot !== ""
    ? Model.joinPath(confRoot, profile)
    : Model.profileConfDir(home, profile)

  // folders.txt and filter.txt can be moved with GDRIVE_FOLDERS / GDRIVE_FILTER
  // from this profile's own config.env, so the buttons that open them resolve
  // the same way gdrive-sync does. config.env has no such override: it is read
  // before the file that could contain one.
  readonly property string foldersPath:
    Model.envValue(configText, "GDRIVE_FOLDERS", Model.joinPath(confDir, "folders.txt"), home)
  readonly property string filterPath:
    Model.envValue(configText, "GDRIVE_FILTER", Model.joinPath(confDir, "filter.txt"), home)
  readonly property string configPath: Model.joinPath(confDir, "config.env")

  // config.env is optional. The button that opens it appears only once the file
  // exists: an editor invoked on a missing path would create it on save with
  // the default umask and without the comments in examples/config.env, while
  // install.sh copies the example and sets the permissions to 600.
  readonly property bool configExists: configFile.ok

  readonly property string stateDir: Model.envValue(configText, "GDRIVE_STATE_DIR",
    stateRootOverride !== "" ? Model.joinPath(stateRootOverride, profile) : Model.profileStateDir(home, profile),
    home)
  readonly property string statusPath: Model.joinPath(stateDir, "status.json")
  readonly property string watcherPath: Model.joinPath(stateDir, "watcher.json")
  readonly property string localRoot:
    Model.envValue(configText, "GDRIVE_LOCAL", Model.profileLocalRoot(home, profile), home)

  // --- derived state ---------------------------------------------------------

  property var status: null          // parsed status.json, or null
  property var watcher: null         // parsed watcher.json, or null
  property string foldersText: ""
  property string configText: ""

  readonly property var folderList: Model.folderSpecs(foldersText)
  readonly property var derived: Model.deriveState({
    now: profileState.now,
    status: profileState.status,
    installed: profileState.installed,
    folderCount: profileState.folderList.length,
    timerActive: profileState.timerActive,
    staleAfterMin: profileState.staleAfterMin,
    stuckAfterMin: profileState.stuckAfterMin
  })
  readonly property string syncState: derived.state
  readonly property string detail: derived.detail
  readonly property bool unconfigured: syncState === "unconfigured"
  readonly property bool syncing: syncState === "syncing"

  readonly property var header: Model.headerSummary(status, now)
  readonly property var folderRows: Model.folderRows(status)
  readonly property string folderSummary: Model.folderSummary(status)
  readonly property var watcherRow: Model.watcherRow(watcher, now)

  // --- actions ---------------------------------------------------------------
  //
  // Every action is a string handed to the caller, which passes it to
  // bar.run(). Nothing here starts a process itself.

  function syncNowCommand() { return Model.syncCommand(profile) }
  function openFolderCommand() { return Model.openPathCommand(localRoot) }
  function editFoldersCommand() { return Model.editFoldersCommand(foldersPath) }
  function editFilterCommand() { return Model.openTextCommand(filterPath) }
  function editConfigCommand() { return configExists ? Model.openTextCommand(configPath) : "" }

  // Retries whatever was not there last time. The shared sources are refreshed
  // by Service.qml, once for every profile together.
  function refresh() {
    if (!statusFile.ok) statusFile.reload()
    if (!watcherFile.ok) watcherFile.reload()
    if (!foldersFile.ok) foldersFile.reload()
    if (!configFile.ok) configFile.reload()
  }

  // --- files -----------------------------------------------------------------
  //
  // FileView cannot watch a file that does not exist yet, so each of these
  // tracks whether it loaded and Service.qml's tick asks again. A missing
  // status.json is a normal state — nothing has run — and never an error.

  FileView {
    id: statusFile
    property bool ok: false
    path: profileState.statusPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      statusFile.ok = true
      profileState.status = Model.parseJson(text())
      profileState.now = Date.now()
    }
    onLoadFailed: {
      statusFile.ok = false
      profileState.status = null
    }
  }

  FileView {
    id: watcherFile
    property bool ok: false
    path: profileState.watcherPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      watcherFile.ok = true
      profileState.watcher = Model.parseJson(text())
      profileState.now = Date.now()
    }
    onLoadFailed: {
      watcherFile.ok = false
      profileState.watcher = null
    }
  }

  FileView {
    id: foldersFile
    property bool ok: false
    path: profileState.foldersPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      foldersFile.ok = true
      profileState.foldersText = String(text() || "")
    }
    onLoadFailed: {
      foldersFile.ok = false
      profileState.foldersText = ""
    }
  }

  FileView {
    id: configFile
    property bool ok: false
    path: profileState.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      configFile.ok = true
      profileState.configText = String(text() || "")
    }
    onLoadFailed: {
      // config.env is optional: without it the defaults apply.
      configFile.ok = false
      profileState.configText = ""
    }
  }
}
