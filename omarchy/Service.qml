import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Everything the widget knows about gdrive-sync, and the only place that talks
// to the outside world.
//
// One widget covers every profile. This object owns the list of them, one
// ProfileState per name, and the sources that are shared rather than
// per-profile:
//   - `gdrive-sync --list-profiles`, a PATH probe and one
//     `systemctl --user is-active` covering every instance at once, polled
//     rarely, because unit state, an installed binary and the set of accounts
//     change about as often as the user reinstalls something.
//   - the clock the "3 min ago" texts and the stale threshold are measured
//     against.
//
// The files themselves are watched inside ProfileState, with FileView: one
// writer per file, each replacing it atomically, so a reader never sees half a
// write and no polling is needed.
//
// No rclone, no sync run, no subprocess per profile per refresh: omarchy-shell
// is a long-lived process shared with the rest of the desktop and must never
// wait on this widget.
Item {
  id: root
  visible: false

  property var settings: ({})
  property string pluginDir: ""

  // --- profiles --------------------------------------------------------------

  property var profiles: []          // names, as --list-profiles printed them
  property var profileStates: []     // the ProfileState objects, in that order

  // The popup shows one profile at a time. The selection is in-memory: a
  // widget cannot write its own settings back, so a bar restart returns to the
  // `defaultProfile` setting rather than to wherever the user last looked.
  property string selectedProfile: ""

  // A child's own state change is not a dependency the binding engine can see
  // through an Instantiator, so every ProfileState pokes this counter and the
  // summaries below depend on it explicitly.
  property int statesRevision: 0

  readonly property var profileSummaries: {
    root.statesRevision                       // dependency, not a statement
    var out = []
    for (var i = 0; i < root.profileStates.length; i++) {
      var state = root.profileStates[i]
      if (!state) continue
      out.push({
        profile: state.profile,
        state: state.syncState,
        detail: state.detail,
        // Anything but "in sync" and "syncing right now" is worth a mark in
        // the picker: the whole point of showing every profile is that a
        // failing one must not hide behind a healthy one.
        attention: Model.stateIsUrgent(state.syncState) || Model.stateIsDim(state.syncState)
      })
    }
    return out
  }

  // What the bar icon shows. The worst state across every profile, never the
  // selected one's: a work account failing for three days must not be hidden
  // behind whichever account the popup happens to be pointing at.
  readonly property string worstState: {
    var states = []
    for (var i = 0; i < root.profileSummaries.length; i++) states.push(root.profileSummaries[i].state)
    return Model.worstState(states)
  }
  readonly property string worstProfile: {
    for (var i = 0; i < root.profileSummaries.length; i++) {
      if (root.profileSummaries[i].state === root.worstState) return root.profileSummaries[i].profile
    }
    return ""
  }
  readonly property string worstDetail: {
    for (var i = 0; i < root.profileSummaries.length; i++) {
      if (root.profileSummaries[i].state === root.worstState) return root.profileSummaries[i].detail
    }
    return "gdrive-sync is not installed"
  }
  readonly property bool syncing: worstState === "syncing"

  // --- the selected profile ----------------------------------------------------
  //
  // The popup body binds to `current`. It is null only while no profile exists
  // at all, which the unconfigured branch of the popup already covers.

  readonly property var current: {
    for (var i = 0; i < root.profileStates.length; i++) {
      if (root.profileStates[i] && root.profileStates[i].profile === root.selectedProfile) {
        return root.profileStates[i]
      }
    }
    return null
  }

  readonly property string syncState: current ? current.syncState : "unconfigured"
  readonly property string detail: current ? current.detail : "gdrive-sync is not installed"
  readonly property bool unconfigured: syncState === "unconfigured"
  readonly property var header: current ? current.header : Model.headerSummary(null, now)
  readonly property var folderRows: current ? current.folderRows : []
  readonly property string folderSummary: current ? current.folderSummary : ""
  readonly property var watcherRow: current ? current.watcherRow : Model.watcherRow(null, now)
  readonly property bool configExists: current ? current.configExists : false

  function selectProfile(name) {
    if (root.profiles.indexOf(String(name)) !== -1) root.selectedProfile = String(name)
  }

  // Keyboard access to the picker: with two accounts this is the whole
  // interaction, and it saves reaching for the mouse.
  function selectNextProfile() {
    if (root.profiles.length < 2) return
    var at = root.profiles.indexOf(root.selectedProfile)
    root.selectedProfile = root.profiles[(at + 1) % root.profiles.length]
  }

  // A selection that no longer names an existing profile is not kept: the
  // account may have been removed since the popup was last open.
  function reconcileSelection() {
    if (root.profiles.indexOf(root.selectedProfile) !== -1) return
    var preferred = String(setting("defaultProfile", ""))
    if (root.profiles.indexOf(preferred) !== -1) root.selectedProfile = preferred
    else root.selectedProfile = root.profiles.length > 0 ? root.profiles[0] : ""
  }

  onProfilesChanged: root.reconcileSelection()

  // --- shared sources ----------------------------------------------------------

  // True until the PATH probe answers. Assuming the tool is present avoids a
  // flash of "not set up" every time the shell starts or reloads plugins.
  property bool installed: true
  property bool probed: false

  // Null means "not asked yet"; otherwise a profile-to-boolean map from the
  // single is-active call below.
  property var timerActive: null

  property double now: Date.now()

  readonly property int staleAfterMin: intSetting("staleAfterMin", Model.DEFAULT_STALE_AFTER_MIN, 5, 1440)
  // The base of the stuck threshold. Model.deriveState adds a minute per
  // folder from status.json and caps the total at the unit's TimeoutStartSec.
  readonly property int stuckAfterMin: intSetting("stuckAfterMin", Model.DEFAULT_STUCK_AFTER_MIN, 5, 240)

  readonly property string home: Quickshell.env("HOME") || ""

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
  // bar.run(). They act on the selected profile, which is the one the popup is
  // showing, and produce nothing at all when there is none.

  function syncNowCommand() { return current ? current.syncNowCommand() : "" }
  function openFolderCommand() { return current ? current.openFolderCommand() : "" }
  // There is no log file: both units log to the journal under their own
  // identifiers, so the action follows the journal instead of opening a path.
  // The identifiers are shared by every instance, which is what makes one
  // reader right for all of them.
  function openLogCommand() { return Model.journalCommand() }
  function installCommand() { return Model.installCommand(pluginDir) }
  function editFoldersCommand() { return current ? current.editFoldersCommand() : "" }
  function editFilterCommand() { return current ? current.editFilterCommand() : "" }
  function editConfigCommand() { return current ? current.editConfigCommand() : "" }

  // Called when the popup opens and on the slow tick. Re-reads the rarely
  // changing sources and retries any file that was not there last time.
  function refresh() {
    root.now = Date.now()
    probeProcess.running = true
    profilesProcess.running = true
    // With no profiles there is no unit to ask about, and `is-active` with an
    // empty argument list is an error rather than an answer.
    if (root.profiles.length > 0) timerProcess.running = true
    for (var i = 0; i < root.profileStates.length; i++) {
      if (root.profileStates[i]) root.profileStates[i].refresh()
    }
  }

  // --- one state object per profile --------------------------------------------

  Instantiator {
    id: profileInstantiator
    model: root.profiles

    // Instantiator hands the object over before it is fully in the list on
    // removal, so the array is rebuilt after the event rather than during it.
    onObjectAdded: Qt.callLater(root.rebuildProfileStates)
    onObjectRemoved: Qt.callLater(root.rebuildProfileStates)

    delegate: ProfileState {
      required property var modelData

      profile: String(modelData)
      home: root.home
      now: root.now
      installed: root.installed
      staleAfterMin: root.staleAfterMin
      stuckAfterMin: root.stuckAfterMin
      timerActive: root.timerActive === null ? null : (root.timerActive[String(modelData)] === true)

      onSyncStateChanged: root.statesRevision++
      onDetailChanged: root.statesRevision++
    }
  }

  function rebuildProfileStates() {
    var out = []
    for (var i = 0; i < profileInstantiator.count; i++) {
      var object = profileInstantiator.objectAt(i)
      if (object) out.push(object)
    }
    root.profileStates = out
    root.statesRevision++
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

  // The directory layout is the profile registry, and gdrive-sync is the one
  // thing that reads it — the same reason line parsing lives only there.
  Process {
    id: profilesProcess
    command: ["bash", "-lc", "gdrive-sync --list-profiles"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.profiles = Model.profilesFromOutput(text)
    }
  }

  // One call for every instance, so the number of processes does not grow with
  // the number of accounts.
  Process {
    id: timerProcess
    command: ["systemctl", "--user", "is-active"].concat(Model.timerUnits(root.profiles))
    stdout: StdioCollector {
      waitForEnd: true
      // `is-active` exits non-zero for every state but active, so the words it
      // prints are the answer and the exit code adds nothing.
      onStreamFinished: root.timerActive = Model.timerActiveMap(text, root.profiles)
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
