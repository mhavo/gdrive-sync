#!/usr/bin/env bash
# The bar widget's state derivation (omarchy/Model.js). Model.js is plain JS
# with no QML imports precisely so this test can run it under node: the icon
# the user sees is decided here, and a rule that only QML can evaluate is a
# rule nobody can check.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null || {
  printf '  skip %s (node missing)\n' "$(basename "$0")"
  exit 0
}

MODEL="$REPO_ROOT/omarchy/Model.js"
assert_path "omarchy/Model.js exists" "$MODEL"
[[ -f "$MODEL" ]] || { finish; exit; }

DRIVER="$(mktemp)"
trap 'rm -f "$DRIVER"' EXIT

# Every case prints "name<TAB>value". The shell side owns the expectations, so
# a wrong answer shows up as a named failure rather than a stack trace.
cat > "$DRIVER" <<'JS'
const M = require(process.argv[2])

const NOW = Date.parse("2026-09-15T15:00:00+03:00")
const min = (n) => NOW - n * 60000

const out = []
const emit = (name, value) => out.push(name + "\t" + String(value))

// A finished, clean run of two folders, three minutes ago.
const healthy = {
  schema: 1,
  version: "1.2.0",
  run: {
    started: new Date(min(4)).toISOString(),
    finished: new Date(min(3)).toISOString(),
    exit: 0,
    trigger: "timer",
    dryRun: false
  },
  folders: [
    { name: "Documents", result: "ok", at: new Date(min(4)).toISOString() },
    { name: "Projects/2026", result: "ok", at: new Date(min(3)).toISOString() }
  ]
}

const clone = (value) => JSON.parse(JSON.stringify(value))
const state = (overrides) => M.deriveState(Object.assign({
  now: NOW,
  installed: true,
  folderCount: 2,
  timerActive: true,
  staleAfterMin: 45,
  stuckAfterMin: 30,
  status: clone(healthy),
  watcher: null
}, overrides)).state

// --- the five icon states ---------------------------------------------------
emit("idle", state({}))
emit("unconfigured-no-binary", state({ installed: false }))
emit("unconfigured-no-folders", state({ folderCount: 0 }))

const running = clone(healthy)
running.run.started = new Date(min(2)).toISOString()
running.run.finished = null
running.run.exit = null
running.folders = [{ name: "Documents", result: "running", at: new Date(min(2)).toISOString() }]
emit("syncing", state({ status: running }))

const failed = clone(healthy)
failed.run.exit = 1
emit("error-exit", state({ status: failed }))

const folderFailed = clone(healthy)
folderFailed.folders[1] = { name: "Archive", result: "error", at: new Date(min(3)).toISOString(),
  reason: "ID does not resolve in Drive" }
emit("error-folder", state({ status: folderFailed }))

const old = clone(healthy)
old.run.started = new Date(min(121)).toISOString()
old.run.finished = new Date(min(120)).toISOString()
emit("stale-old", state({ status: old }))
emit("stale-timer-inactive", state({ timerActive: false }))
emit("stale-no-status", state({ status: null }))

// --- exit 75 is not a failure ----------------------------------------------
const lockHeld = clone(healthy)
lockHeld.run.exit = 75
lockHeld.folders = []
emit("exit-75-not-error", state({ status: lockHeld }))
emit("exit-75-is-failed-exit", M.isFailedExit(lockHeld.run))
emit("exit-1-is-failed-exit", M.isFailedExit({ exit: 1 }))
emit("exit-0-is-failed-exit", M.isFailedExit({ exit: 0 }))

// --- a crashed run: unfinished, but too old to still be running -------------
const crashed = clone(healthy)
crashed.run.started = new Date(min(90)).toISOString()
crashed.run.finished = null
crashed.run.exit = null
emit("crashed-run", state({ status: crashed }))
emit("crashed-run-detail", M.deriveState({
  now: NOW, installed: true, folderCount: 2, timerActive: true, status: crashed
}).detail)

// A run just under the stuck threshold is still syncing; just over it is not.
const nearlyStuck = clone(crashed)
nearlyStuck.run.started = new Date(min(29)).toISOString()
emit("unfinished-within-stuck", state({ status: nearlyStuck }))
// The healthy fixture has two folders, so the effective threshold is 30 + 2.
const justStuck = clone(crashed)
justStuck.run.started = new Date(min(33)).toISOString()
emit("unfinished-past-stuck", state({ status: justStuck }))

// --- priority order ---------------------------------------------------------
// unconfigured outranks everything, even a failed run.
emit("priority-unconfigured-over-error", state({ installed: false, status: failed }))
// syncing outranks error: a folder that already failed does not stop the run.
const runningWithError = clone(running)
runningWithError.folders.push({ name: "Archive", result: "error", at: new Date(min(2)).toISOString(),
  reason: "ID does not resolve in Drive" })
emit("priority-syncing-over-error", state({ status: runningWithError }))
// error outranks stale: an old failed run still reads as an error.
const oldAndFailed = clone(old)
oldAndFailed.run.exit = 1
emit("priority-error-over-stale", state({ status: oldAndFailed }))
// error outranks stale even when the timer is off.
emit("priority-error-over-inactive-timer", state({ status: failed, timerActive: false }))
// stale outranks idle.
emit("priority-stale-over-idle", state({ status: old, timerActive: true }))

// --- settings are honoured --------------------------------------------------
emit("stale-threshold-respected", state({ status: old, staleAfterMin: 180 }))
emit("stuck-threshold-respected", state({ status: justStuck, stuckAfterMin: 60 }))

// --- appearance mapping -----------------------------------------------------
emit("urgent-only-on-error", [M.stateIsUrgent("error"), M.stateIsUrgent("stale"),
  M.stateIsUrgent("idle"), M.stateIsUrgent("syncing"), M.stateIsUrgent("unconfigured")].join(","))
emit("dim-states", [M.stateIsDim("unconfigured"), M.stateIsDim("stale"),
  M.stateIsDim("idle")].join(","))
emit("glyphs-differ", new Set(["unconfigured", "syncing", "error", "stale", "idle"]
  .map(M.stateGlyph)).size)
emit("glyph-fallback", M.stateGlyph("nonsense") === M.stateGlyph("idle"))

// --- broken and missing input -----------------------------------------------
emit("parse-missing", M.parseJson("") === null)
emit("parse-truncated", M.parseJson('{"schema": 1, "run": {') === null)
emit("parse-not-object", M.parseJson("42") === null)
emit("bad-json-state", state({ status: M.parseJson("{oops") }))
emit("status-without-run", state({ status: { schema: 1, folders: [] } }))
emit("unparsable-timestamps", state({ status: { run: { started: "yesterday", finished: "soon", exit: 0 } } }))
emit("millis-of-garbage", M.toMillis("not a time") === null)

// --- the stuck threshold grows with the folder count ------------------------
// An honest run of a hundred folders outlasts the 30-minute base, so the base
// is only a base: +1 min per folder, capped at the unit's TimeoutStartSec=2h.
emit("stuck-two-folders", M.effectiveStuckMin(30, 2))
emit("stuck-hundred-folders", M.effectiveStuckMin(30, 100))
emit("stuck-ceiling-is-two-hours", M.effectiveStuckMin(240, 100))
emit("stuck-no-folders", M.effectiveStuckMin(30, 0))
emit("stuck-folder-count-from-status", M.statusFolderCount(healthy))
emit("stuck-folder-count-of-nothing", M.statusFolderCount(null))

const manyFolders = (count, minutesAgo) => {
  const status = clone(healthy)
  status.run.started = new Date(min(minutesAgo)).toISOString()
  status.run.finished = null
  status.run.exit = null
  status.folders = []
  for (let i = 0; i < count; i++) {
    status.folders.push({ name: "Folder " + i, result: "running", at: status.run.started })
  }
  return status
}

// Two folders: the base still applies, so 40 minutes in is stuck.
emit("two-folders-40min", state({ status: manyFolders(2, 40), folderCount: 2 }))
emit("two-folders-31min", state({ status: manyFolders(2, 31), folderCount: 2 }))
emit("two-folders-33min", state({ status: manyFolders(2, 33), folderCount: 2 }))
emit("two-folders-29min", state({ status: manyFolders(2, 29), folderCount: 2 }))
// A hundred folders: 40 and even 119 minutes in is a real run, not stale.
emit("hundred-folders-40min", state({ status: manyFolders(100, 40), folderCount: 100 }))
emit("hundred-folders-119min", state({ status: manyFolders(100, 119), folderCount: 100 }))
// Past two hours no run can still be alive: systemd has killed it.
emit("hundred-folders-121min", state({ status: manyFolders(100, 121), folderCount: 100 }))
emit("hundred-folders-121min-detail", M.deriveState({
  now: NOW, installed: true, folderCount: 100, timerActive: true, status: manyFolders(100, 121)
}).detail)

// --- a missing `log` field breaks nothing -----------------------------------
// gdrive-sync writes no log file and status.json has no `log` key; a widget
// that used to read one must not depend on it.
emit("no-log-field-in-fixture", ("log" in healthy) === false)
emit("no-log-field-state", state({}))
emit("no-log-field-header", M.headerSummary(healthy, NOW).title)
emit("no-log-field-rows", M.folderRows(healthy).length)
const withLegacyLog = clone(healthy)
withLegacyLog.log = "/tmp/legacy.log"
emit("legacy-log-field-ignored", state({ status: withLegacyLog }) === state({}))

// --- the journal is the log --------------------------------------------------
emit("journal-command", M.journalCommand())
emit("journal-covers-both-units",
  /-t gdrive-sync/.test(M.journalCommand()) && /-t gdrive-watch/.test(M.journalCommand()))
emit("journal-opens-a-terminal", /^omarchy-launch-terminal /.test(M.journalCommand()))
emit("journal-reads-no-file", !/--log-file|\.log/.test(M.journalCommand()))

// --- folder list ------------------------------------------------------------
emit("folder-specs-count", M.folderSpecs("# comment\nDocuments\n\n  Projects/2026  # trailing\n#Archive\n").length)
emit("folder-specs-empty-file", M.folderSpecs("# only comments\n\n").length)
emit("folder-rows-count", M.folderRows(folderFailed).length)
// Row 0 is the failure now: folderRows sorts deviations to the top.
emit("folder-row-reason", M.folderRows(folderFailed)[0].reason)
emit("folder-row-ok-has-no-reason", M.folderRows(folderFailed)[1].reason === "")
emit("folder-row-urgent", M.folderRows(folderFailed)[0].urgent)
emit("folder-rows-of-nothing", M.folderRows(null).length)

// --- deviations first, folders.txt order kept inside each group -------------
// One failure on line 87 of a hundred must not sit below 86 fine rows.
const mixed = clone(healthy)
mixed.folders = [
  { name: "A-ok", result: "ok", at: new Date(min(5)).toISOString() },
  { name: "B-running", result: "running", at: new Date(min(5)).toISOString() },
  { name: "C-ok", result: "ok", at: new Date(min(5)).toISOString() },
  { name: "D-error", result: "error", at: new Date(min(5)).toISOString(), reason: "boom" },
  { name: "E-skipped", result: "skipped", at: new Date(min(5)).toISOString(), reason: "empty" },
  { name: "F-initialising", result: "initialising", at: new Date(min(5)).toISOString() },
  { name: "G-error", result: "error", at: new Date(min(5)).toISOString(), reason: "boom too" },
  { name: "H-nonsense", result: "wat", at: new Date(min(5)).toISOString() }
]
emit("rows-ordered-by-severity", M.folderRows(mixed).map((r) => r.name).join(","))
// Stability: two ok rows keep folders.txt order rather than an alphabet.
const stableCheck = clone(healthy)
stableCheck.folders = [
  { name: "Zebra", result: "ok" }, { name: "Apple", result: "ok" }, { name: "Mango", result: "ok" }
]
emit("rows-not-alphabetical", M.folderRows(stableCheck).map((r) => r.name).join(","))
// Nothing is dropped: every row still reaches the scrollable list.
const hundred = { folders: [] }
for (let i = 0; i < 100; i++) {
  hundred.folders.push({ name: "Folder " + i, result: i === 86 ? "error" : "ok", reason: i === 86 ? "gone" : "" })
}
emit("hundred-rows-all-present", M.folderRows(hundred).length)
emit("hundred-rows-error-first", M.folderRows(hundred)[0].name)

// --- the header summary appears only when the list stops fitting ------------
emit("summary-of-two-folders", M.folderSummary(healthy) === "")
emit("summary-of-hundred", M.folderSummary(hundred))
emit("summary-singular-error", M.folderSummary(hundred).indexOf("1 error") !== -1)
const busy = { folders: [] }
for (let i = 0; i < 12; i++) {
  busy.folders.push({ name: "Folder " + i, result: i < 3 ? "ok" : (i < 5 ? "skipped" : "running") })
}
emit("summary-groups", M.folderSummary(busy))
emit("summary-of-nothing", M.folderSummary(null) === "")

// --- watcher ----------------------------------------------------------------
const watcher = { schema: 1, state: "pending", pending: ["Documents"], since: new Date(min(1)).toISOString(), nextRetry: null }
emit("watcher-state", M.watcherRow(watcher, NOW).state)
emit("watcher-pending-detail", M.watcherRow(watcher, NOW).detail)
emit("watcher-stopped", M.watcherRow({ state: "stopped", pending: [] }, NOW).label)
emit("watcher-absent", M.watcherRow(null, NOW).present)

// --- header -----------------------------------------------------------------
emit("header-title", M.headerSummary(healthy, NOW).title)
emit("header-meta", M.headerSummary(healthy, NOW).meta)
emit("header-running", M.headerSummary(running, NOW).title)
emit("header-none", M.headerSummary(null, NOW).title)
emit("header-lock-held", M.headerSummary(lockHeld, NOW).meta)
emit("duration", M.formatDuration(M.runDuration(healthy)))
emit("duration-long", M.formatDuration(3725000))

// --- config parsing ---------------------------------------------------------
const configEnv = [
  "# Settings for gdrive-sync",
  "#GDRIVE_LOCAL=$HOME/GoogleDrive",
  'GDRIVE_LOCAL="$HOME/Drive Files"',
  "GDRIVE_STATE_DIR=$HOME/.local/state/gdrive-sync/work"
].join("\n")
emit("config-local-root", M.envValue(configEnv, "GDRIVE_LOCAL", "/fallback", "/home/u"))
emit("config-state-dir", M.envValue(configEnv, "GDRIVE_STATE_DIR", "/fallback", "/home/u"))
emit("config-missing-key", M.envValue(configEnv, "GDRIVE_REMOTE", "GoogleDrive", "/home/u"))
emit("config-commented-out-only", M.envValue("#GDRIVE_LOCAL=$HOME/Nope\n", "GDRIVE_LOCAL", "/fallback", "/home/u"))

// The buttons that open folders.txt and filter.txt must resolve the same
// overrides gdrive-sync honours, or they open a file the tool is not reading.
const confDir = M.profileConfDir("/home/u", "work")
const movedEnv = [
  "GDRIVE_FOLDERS=$HOME/Sync/folders.txt",
  'GDRIVE_FILTER="$HOME/Sync/my filter.txt"'
].join("\n")
emit("folders-path-default", M.envValue("", "GDRIVE_FOLDERS", M.joinPath(confDir, "folders.txt"), "/home/u"))
emit("filter-path-default", M.envValue("", "GDRIVE_FILTER", M.joinPath(confDir, "filter.txt"), "/home/u"))
emit("folders-path-overridden", M.envValue(movedEnv, "GDRIVE_FOLDERS", M.joinPath(confDir, "folders.txt"), "/home/u"))
emit("filter-path-overridden", M.envValue(movedEnv, "GDRIVE_FILTER", M.joinPath(confDir, "filter.txt"), "/home/u"))
emit("edit-filter-quoted", M.openTextCommand("/home/u/Sync/my filter.txt"))
emit("edit-config-uses-editor", /omarchy-launch-editor/.test(M.openTextCommand(M.joinPath(confDir, "config.env"))))
emit("edit-nothing", M.openTextCommand("") === "")

// --- commands are fire-and-forget, and never run rclone ---------------------
emit("open-folder-quoted", M.openPathCommand("/home/u/Drive Files"))
emit("open-nothing", M.openPathCommand("") === "")
emit("quote-hostile-name", M.shellQuote("Photos [2026]'s"))
emit("install-command-has-no-sudo", !/sudo/.test(M.installCommand("/plugins/mhavo.gdrive-sync")))
emit("install-command-mentions-script", /install\.sh/.test(M.installCommand("/plugins/mhavo.gdrive-sync")))
emit("plugin-dir-from-url", M.pluginDirFromUrl("file:///home/u/.config/omarchy/plugins/mhavo.gdrive-sync/omarchy/"))
emit("timer-active-parsing", [M.timerActiveFromOutput("active\n"), M.timerActiveFromOutput("inactive\n")].join(","))

// --- the worst state across every profile -----------------------------------
// The bar shows one icon for several accounts, so the ordering here is not
// deriveState's. There `unconfigured` outranks everything because a widget
// that cannot work says so first; across profiles a *working* account that is
// actually broken has to win over one that was never set up, or a work
// account failing for three days hides behind a personal one nobody uses.
emit("worst-of-nothing", M.worstState([]))
emit("worst-single", M.worstState(["syncing"]))
emit("worst-error-wins", M.worstState(["idle", "error", "syncing"]))
emit("worst-syncing-over-stale", M.worstState(["stale", "syncing", "idle"]))
emit("worst-stale-over-unconfigured", M.worstState(["unconfigured", "stale"]))
emit("worst-unconfigured-over-idle", M.worstState(["idle", "unconfigured", "idle"]))
emit("worst-all-idle", M.worstState(["idle", "idle"]))
emit("worst-unknown-reads-as-idle", M.worstState(["nonsense"]))
emit("worst-unknown-loses-to-stale", M.worstState(["nonsense", "stale"]))
emit("worst-of-garbage", M.worstState(null))

// --- units and commands carry the profile -----------------------------------
emit("sync-command", M.syncCommand("work"))
emit("timer-unit", M.timerUnit("work"))
emit("sync-command-avoids-cli",
  /gdrive-sync@work\.service$/.test(M.syncCommand("work")) && !/rclone/.test(M.syncCommand("work")))
emit("sync-command-no-profile", M.syncCommand("") === "")
emit("timer-unit-no-profile", M.timerUnit("") === "")
// A name reaches systemd and a shell command line unquoted, so anything the
// CLI would have refused is refused here too rather than escaped.
emit("sync-command-rejects-a-space", M.syncCommand("not a name") === "")
emit("timer-unit-rejects-a-slash", M.timerUnit("a/b") === "")
emit("profile-name-checks",
  [M.isProfileName("."), M.isProfileName(".."), M.isProfileName("a.b"), M.isProfileName("A_0-9")].join(","))
emit("timer-units-for-several", M.timerUnits(["work", "personal"]).join(" "))
emit("timer-units-skip-invalid", M.timerUnits(["work", "not a name", ""]).join(" "))
emit("timer-units-of-nothing", M.timerUnits([]).length)

// --- the profile list, as --list-profiles prints it -------------------------
emit("profiles-from-output", M.profilesFromOutput("work\npersonal\n").join(","))
emit("profiles-trimmed", M.profilesFromOutput("  work  \n\n personal\n").join(","))
emit("profiles-empty", M.profilesFromOutput("").length)
emit("profiles-drop-invalid", M.profilesFromOutput("work\nnot a profile\n../escape\n").join(","))
emit("profiles-of-garbage", M.profilesFromOutput(null).length)

// --- one is-active call answers for every instance --------------------------
// `systemctl is-active a b` prints one word per unit, in the order asked, so
// the answer is read positionally. A short answer leaves the rest unknown,
// which is `false` here: an unreported timer is not a running one.
emit("timer-map-both", JSON.stringify(M.timerActiveMap("active\ninactive\n", ["work", "personal"])))
emit("timer-map-short-output", JSON.stringify(M.timerActiveMap("active\n", ["work", "personal"])))
emit("timer-map-no-output", JSON.stringify(M.timerActiveMap("", ["work"])))
emit("timer-map-no-profiles", JSON.stringify(M.timerActiveMap("active\n", [])))
emit("timer-map-other-words", JSON.stringify(M.timerActiveMap("failed\nactivating\n", ["a", "b"])))

// --- roots, and the directories a profile owns under them -------------------
emit("conf-root", M.defaultConfRoot("/home/u"))
emit("state-root", M.defaultStateRoot("/home/u"))
emit("profile-conf-dir", M.profileConfDir("/home/u", "work"))
emit("profile-state-dir", M.profileStateDir("/home/u", "work"))
emit("profile-local-root", M.profileLocalRoot("/home/u", "work"))
// The rclone- prefix named an implementation detail and is gone with the
// breaking change; nothing may quietly put it back.
emit("roots-dropped-the-rclone-prefix",
  !/rclone/.test(M.defaultConfRoot("/home/u") + M.defaultStateRoot("/home/u")))

process.stdout.write(out.join("\n") + "\n")
JS

declare -A got=()
while IFS=$'\t' read -r key value; do
  [[ -n "$key" ]] && got["$key"]="$value"
done < <(node "$DRIVER" "$MODEL")

expect() { assert_eq "$1" "$2" "${got[$1]-<no such case>}"; }

# The five icon states from the design table.
expect idle idle
expect unconfigured-no-binary unconfigured
expect unconfigured-no-folders unconfigured
expect syncing syncing
expect error-exit error
expect error-folder error
expect stale-old stale
expect stale-timer-inactive stale
expect stale-no-status stale

# exit 75 means the lock was held. That is the timer working, not a failure.
expect exit-75-not-error idle
expect exit-75-is-failed-exit false
expect exit-1-is-failed-exit true
expect exit-0-is-failed-exit false

# A run that died leaves finished=null forever; age, not the lock file, catches it.
expect crashed-run stale
expect crashed-run-detail "A run started but never finished"
expect unfinished-within-stuck syncing
expect unfinished-past-stuck stale

# Priority order, top to bottom.
expect priority-unconfigured-over-error unconfigured
expect priority-syncing-over-error syncing
expect priority-error-over-stale error
expect priority-error-over-inactive-timer error
expect priority-stale-over-idle stale

expect stale-threshold-respected idle
expect stuck-threshold-respected syncing

expect urgent-only-on-error "true,false,false,false,false"
expect dim-states "true,true,false"
expect glyphs-differ 5
expect glyph-fallback true

# Missing or broken input is "no data", never a crash.
expect parse-missing true
expect parse-truncated true
expect parse-not-object true
expect bad-json-state stale
expect status-without-run stale
expect unparsable-timestamps stale
expect millis-of-garbage true

expect folder-specs-count 2
expect folder-specs-empty-file 0
expect folder-rows-count 2
expect folder-row-reason "ID does not resolve in Drive"
expect folder-row-ok-has-no-reason true
expect folder-row-urgent true
expect folder-rows-of-nothing 0

# stuckAfterMin is a base: +1 min per folder, capped at TimeoutStartSec=2h.
expect stuck-two-folders 32
expect stuck-hundred-folders 120
expect stuck-ceiling-is-two-hours 120
expect stuck-no-folders 30
expect stuck-folder-count-from-status 2
expect stuck-folder-count-of-nothing 0
expect two-folders-40min stale
expect two-folders-31min syncing
expect two-folders-33min stale
expect two-folders-29min syncing
expect hundred-folders-40min syncing
expect hundred-folders-119min syncing
expect hundred-folders-121min stale
expect hundred-folders-121min-detail "A run started but never finished"

# There is no log file and no `log` field; nothing may depend on one.
expect no-log-field-in-fixture true
expect no-log-field-state idle
expect no-log-field-header "Synced 3 min ago"
expect no-log-field-rows 2
expect legacy-log-field-ignored true

expect journal-command "omarchy-launch-terminal bash -lc 'journalctl --user -t gdrive-sync -t gdrive-watch -f'"
expect journal-covers-both-units true
expect journal-opens-a-terminal true
expect journal-reads-no-file true

# Deviations first, folders.txt order preserved inside each group.
expect rows-ordered-by-severity "D-error,G-error,E-skipped,B-running,F-initialising,H-nonsense,A-ok,C-ok"
expect rows-not-alphabetical "Zebra,Apple,Mango"
expect hundred-rows-all-present 100
expect hundred-rows-error-first "Folder 86"

expect summary-of-two-folders true
expect summary-of-hundred "99 ok · 1 error"
expect summary-singular-error true
expect summary-groups "3 ok · 2 skipped · 7 in progress"
expect summary-of-nothing true

expect watcher-state pending
expect watcher-pending-detail Documents
expect watcher-stopped "Watcher stopped"
expect watcher-absent false

expect header-title "Synced 3 min ago"
expect header-meta "timer · 1m"
expect header-running "Syncing now"
expect header-none "No sync recorded"
expect header-lock-held "timer · 1m · lock was held"
expect duration 1m
expect duration-long "1h 2m"

expect config-local-root "/home/u/Drive Files"
expect config-state-dir "/home/u/.local/state/gdrive-sync/work"
expect config-missing-key GoogleDrive
expect config-commented-out-only /fallback

expect open-folder-quoted "xdg-open '/home/u/Drive Files'"
expect folders-path-default "/home/u/.config/gdrive-sync/work/folders.txt"
expect filter-path-default "/home/u/.config/gdrive-sync/work/filter.txt"
expect folders-path-overridden "/home/u/Sync/folders.txt"
expect filter-path-overridden "/home/u/Sync/my filter.txt"
expect edit-filter-quoted "if command -v omarchy-launch-editor >/dev/null 2>&1; then omarchy-launch-editor '/home/u/Sync/my filter.txt'; else xdg-open '/home/u/Sync/my filter.txt'; fi"
expect edit-config-uses-editor true
expect edit-nothing true
expect open-nothing true
expect quote-hostile-name "'Photos [2026]'\\''s'"
expect install-command-has-no-sudo true
expect install-command-mentions-script true
expect plugin-dir-from-url "/home/u/.config/omarchy/plugins/mhavo.gdrive-sync"
expect timer-active-parsing "true,false"

# The bar icon speaks for every profile at once.
expect worst-of-nothing unconfigured
expect worst-single syncing
expect worst-error-wins error
expect worst-syncing-over-stale syncing
expect worst-stale-over-unconfigured stale
expect worst-unconfigured-over-idle unconfigured
expect worst-all-idle idle
expect worst-unknown-reads-as-idle idle
expect worst-unknown-loses-to-stale stale
expect worst-of-garbage unconfigured

expect sync-command "systemctl --user start gdrive-sync@work.service"
expect timer-unit "gdrive-sync@work.timer"
expect sync-command-avoids-cli true
expect sync-command-no-profile true
expect timer-unit-no-profile true
expect sync-command-rejects-a-space true
expect timer-unit-rejects-a-slash true
expect profile-name-checks "false,false,true,true"
expect timer-units-for-several "gdrive-sync@work.timer gdrive-sync@personal.timer"
expect timer-units-skip-invalid "gdrive-sync@work.timer"
expect timer-units-of-nothing 0

expect profiles-from-output "work,personal"
expect profiles-trimmed "work,personal"
expect profiles-empty 0
expect profiles-drop-invalid work
expect profiles-of-garbage 0

expect timer-map-both '{"work":true,"personal":false}'
expect timer-map-short-output '{"work":true,"personal":false}'
expect timer-map-no-output '{"work":false}'
expect timer-map-no-profiles '{}'
expect timer-map-other-words '{"a":false,"b":false}'

expect conf-root "/home/u/.config/gdrive-sync"
expect state-root "/home/u/.local/state/gdrive-sync"
expect profile-conf-dir "/home/u/.config/gdrive-sync/work"
expect profile-state-dir "/home/u/.local/state/gdrive-sync/work"
expect profile-local-root "/home/u/GoogleDrive/work"
expect roots-dropped-the-rclone-prefix true

finish
