// State derivation for the gdrive-sync Omarchy bar widget.
//
// Everything here is a pure function over plain values: no QML types, no
// imports, no side effects. Service.qml reads the files and calls into this;
// tests/test-widget-model.sh runs the very same file under node. A rule that
// lives in QML is a rule nobody can test, so no rule lives in QML.

// ---------------------------------------------------------------- constants

// 75 is EX_TEMPFAIL. gdrive-sync exits with it when another run already holds
// the lock, and gdrive-sync@.service declares SuccessExitStatus=75. An
// overlapping run is the timer working as designed, so it is never an error.
var EXIT_LOCK_HELD = 75

var DEFAULT_STALE_AFTER_MIN = 45
var DEFAULT_STUCK_AFTER_MIN = 30

// stuckAfterMin is a base, not the whole threshold. An honest run costs time
// per folder — two folders finish in a minute, a hundred do not — so the
// effective threshold grows with the number of folders status.json names.
// Without that, a real run of a hundred folders would cross the base
// threshold while still working and the widget would report `stale`, which is
// a lie.
var STUCK_PER_FOLDER_MIN = 1

// The ceiling is not a taste decision: systemd/gdrive-sync@.service sets
// TimeoutStartSec=2h, so systemd kills any run that lives longer. A run older
// than 120 minutes cannot exist, which makes anything past it stuck by
// definition and leaves no reason to wait further.
var STUCK_CEILING_MIN = 120

// Above this many folders the list no longer fits in one glance, so the
// section header carries a count summary as well. Every row stays in the
// scrollable list either way; the summary only saves the eye a scroll.
var FOLDER_SUMMARY_THRESHOLD = 8

// Row order in the popup: deviations first, `ok` last. With a hundred folders
// the one failure on line 87 would otherwise be buried under 86 fine rows,
// and surfacing deviations is the entire point of the widget. Sorting is
// stable, so folders.txt order survives inside each group.
var RESULT_RANK = {
  error: 0,
  skipped: 1,
  running: 2,
  initialising: 2,
  unknown: 3,
  ok: 4
}

// Roots, not directories: a profile owns <root>/<profile>. The rclone- prefix
// the old paths carried named an implementation detail of the sync, which the
// widget never had any business knowing about.
var DEFAULT_CONF_ROOT = ".config/gdrive-sync"
var DEFAULT_STATE_ROOT = ".local/state/gdrive-sync"
var DEFAULT_LOCAL_ROOT = "GoogleDrive"

// The bar shows one icon for every profile, so the states have to be ordered
// against each other. This is not deriveState's priority list: there
// `unconfigured` wins because a widget that cannot work must say so before
// anything else, while here an account that is genuinely broken has to outrank
// one that was never set up. Otherwise a work account failing for three days
// hides behind a personal one nobody ever configured.
var STATE_URGENCY = {
  error: 0,
  syncing: 1,
  stale: 2,
  unconfigured: 3,
  idle: 4
}

// systemd instance names, and part of the command lines built below. The CLI
// validates the same set, so a name outside it did not come from a profile
// directory and is dropped rather than escaped.
var PROFILE_NAME_RE = /^[A-Za-z0-9._-]+$/

// Material Design icons from the Nerd Font the bar already uses.
var GLYPHS = {
  unconfigured: "󰨹",   // md-cloud_question
  syncing: "󰓦",        // md-sync
  error: "󰓧",          // md-sync_alert
  stale: "󰓨",          // md-sync_off
  idle: "󰊶"            // md-google_drive
}

var FOLDER_GLYPHS = {
  ok: "󰗡",             // md-check_circle_outline
  error: "󰗖",          // md-alert_circle_outline
  skipped: "󰮍",        // md-dots_horizontal_circle_outline
  initialising: "󰦖",   // md-progress_clock
  running: "󰓦",        // md-sync
  unknown: "󰇘"         // md-dots_horizontal
}

var WATCHER_GLYPHS = {
  watching: "󰛐",       // md-eye_outline
  pending: "󰔟",        // md-timer_sand
  syncing: "󰓦",        // md-sync
  retry: "󰑐",          // md-refresh
  stopped: "󰏦",        // md-pause_circle_outline
  unknown: "󰇘"         // md-dots_horizontal
}

// ------------------------------------------------------------ small helpers

function isObject(value) {
  return value !== null && value !== undefined && typeof value === "object"
}

function isArray(value) {
  return isObject(value) && typeof value.length === "number"
}

function str(value) {
  return value === null || value === undefined ? "" : String(value)
}

function trim(value) {
  return str(value).replace(/^\s+/, "").replace(/\s+$/, "")
}

function intOr(value, fallback) {
  var n = parseInt(str(value), 10)
  return isFinite(n) ? n : fallback
}

function clampInt(value, fallback, min, max) {
  var n = intOr(value, fallback)
  if (n < min) n = min
  if (n > max) n = max
  return n
}

// A missing or unreadable file is "no data", never a crash: every reader here
// takes text of unknown quality and answers with null rather than throwing.
function parseJson(text) {
  var raw = trim(text)
  if (raw === "") return null
  try {
    var parsed = JSON.parse(raw)
    return isObject(parsed) ? parsed : null
  } catch (e) {
    return null
  }
}

// ISO 8601 with an offset, as gdrive-sync writes it. Anything else is null,
// which every caller treats as "unknown", not as the epoch.
function toMillis(value) {
  if (value === null || value === undefined) return null
  var text = trim(value)
  if (text === "") return null
  var ms = Date.parse(text)
  return isFinite(ms) ? ms : null
}

// Single quotes survive everything a folder name can contain: spaces,
// brackets, non-ASCII, and the embedded quote itself.
function shellQuote(value) {
  return "'" + str(value).split("'").join("'\\''") + "'"
}

// ----------------------------------------------------------------- config

// Mirrors load_lines() in gdrive-sync: a comment runs to end of line, trailing
// space is dropped, blank lines do not count. An empty result means the tool
// has nothing to sync, which the widget shows as unconfigured.
function folderSpecs(text) {
  var lines = str(text).split(/\r?\n/)
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = trim(lines[i].replace(/#.*$/, ""))
    if (line !== "") out.push(line)
  }
  return out
}

function expandHome(value, home) {
  var text = str(value)
  var base = str(home)
  if (base === "") return text
  if (text === "~") return base
  text = text.replace(/^~\//, base + "/")
  text = text.replace(/\$\{HOME\}/g, base)
  text = text.replace(/\$HOME/g, base)
  return text
}

// config.env is bash, but the widget only needs plain `KEY=value` assignments
// out of it and refuses to guess at anything cleverer. The last assignment
// wins, as it would when bash sourced the file.
function envValue(text, key, fallback, home) {
  var lines = str(text).split(/\r?\n/)
  var pattern = new RegExp("^\\s*(?:export\\s+)?" + key + "\\s*=\\s*(.*)$")
  var found = null
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (/^\s*#/.test(line)) continue
    var match = pattern.exec(line)
    if (!match) continue
    var raw = trim(match[1])
    if (raw.charAt(0) === '"' && raw.lastIndexOf('"') > 0) {
      found = raw.slice(1, raw.lastIndexOf('"'))
    } else if (raw.charAt(0) === "'" && raw.lastIndexOf("'") > 0) {
      found = raw.slice(1, raw.lastIndexOf("'"))
    } else {
      found = trim(raw.replace(/\s+#.*$/, "").split(/\s/)[0] || "")
    }
  }
  if (found === null || found === "") return str(fallback)
  return expandHome(found, home)
}

function joinPath(base, leaf) {
  var head = str(base).replace(/\/+$/, "")
  var tail = str(leaf).replace(/^\/+/, "")
  if (head === "") return tail
  if (tail === "") return head
  return head + "/" + tail
}

function defaultConfRoot(home) { return joinPath(home, DEFAULT_CONF_ROOT) }
function defaultStateRoot(home) { return joinPath(home, DEFAULT_STATE_ROOT) }
function defaultLocalRoot(home) { return joinPath(home, DEFAULT_LOCAL_ROOT) }

function profileConfDir(home, profile) { return joinPath(defaultConfRoot(home), profile) }
function profileStateDir(home, profile) { return joinPath(defaultStateRoot(home), profile) }
// install.sh gives a new profile this root by default, which is what keeps two
// profiles from sharing one local directory without anybody having to think
// about it.
function profileLocalRoot(home, profile) { return joinPath(defaultLocalRoot(home), profile) }

// ----------------------------------------------------------------- profiles

function isProfileName(value) {
  var name = trim(value)
  if (name === "." || name === "..") return false
  return PROFILE_NAME_RE.test(name)
}

// The lines of `gdrive-sync --list-profiles`. A name the CLI would not accept
// cannot name a unit either, so it is dropped here rather than carried into a
// command line.
function profilesFromOutput(text) {
  var lines = str(text).split(/\r?\n/)
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var name = trim(lines[i])
    if (isProfileName(name)) out.push(name)
  }
  return out
}

function stateUrgency(state) {
  var key = str(state)
  // An unrecognised state ranks — and reads — as idle, the same fallback
  // stateGlyph makes. Inventing urgency out of a word nobody wrote would put
  // an icon on the bar that no code here can explain.
  return STATE_URGENCY[key] !== undefined ? STATE_URGENCY[key] : STATE_URGENCY.idle
}

// One icon for several accounts. With no profiles at all there is nothing to
// report on, which is exactly what `unconfigured` says.
function worstState(states) {
  if (!isArray(states) || states.length === 0) return "unconfigured"
  var best = "idle"
  var bestRank = STATE_URGENCY.idle
  for (var i = 0; i < states.length; i++) {
    var key = str(states[i])
    var rank = stateUrgency(key)
    if (rank < bestRank) {
      bestRank = rank
      best = STATE_URGENCY[key] !== undefined ? key : "idle"
    }
  }
  return best
}

// Panel.qml lives in <plugin>/omarchy/, so the repository root that carries
// install.sh is one level up from the QML file's own directory.
function pluginDirFromUrl(url) {
  var text = str(url).replace(/^file:\/\//, "").replace(/\/+$/, "")
  if (text === "") return ""
  var cut = text.lastIndexOf("/")
  return cut > 0 ? text.slice(0, cut) : text
}

// ------------------------------------------------------------ status reading

function runOf(status) {
  return isObject(status) && isObject(status.run) ? status.run : null
}

// The lock file is not a signal — gdrive-sync creates it unconditionally — so
// "in progress" is exactly `run.finished === null`, and nothing else.
function isUnfinished(run) {
  if (!run) return false
  if (!("finished" in run)) return true
  return run.finished === null || run.finished === undefined || trim(run.finished) === ""
}

function isFailedExit(run) {
  if (!run) return false
  if (run.exit === null || run.exit === undefined) return false
  var code = Number(run.exit)
  if (!isFinite(code)) return false
  return code !== 0 && code !== EXIT_LOCK_HELD
}

function lockWasHeld(run) {
  return !!run && Number(run.exit) === EXIT_LOCK_HELD
}

// The count comes from status.json, which names every selected folder from
// the moment the run starts (gdrive-sync's status_init_folders marks them all
// `running`), so the threshold is right for the run actually in progress and
// not for whatever folders.txt happens to say now.
function statusFolderCount(status) {
  var folders = isObject(status) ? status.folders : null
  return isArray(folders) ? folders.length : 0
}

// base + 1 min per folder, capped at the unit's own TimeoutStartSec=2h.
function effectiveStuckMin(stuckAfterMin, folderCount) {
  var base = clampInt(stuckAfterMin, DEFAULT_STUCK_AFTER_MIN, 5, 240)
  var count = intOr(folderCount, 0)
  if (count < 0) count = 0
  var total = base + count * STUCK_PER_FOLDER_MIN
  return total > STUCK_CEILING_MIN ? STUCK_CEILING_MIN : total
}

function hasFolderError(status) {
  var folders = isObject(status) ? status.folders : null
  if (!isArray(folders)) return false
  for (var i = 0; i < folders.length; i++) {
    if (isObject(folders[i]) && str(folders[i].result) === "error") return true
  }
  return false
}

// -------------------------------------------------------------- bar state

// The one function the bar icon is made of. Conditions are tested in the
// order the design document lists them, so a run that is both unfinished and
// carrying a failed folder reads as syncing until it finishes.
function deriveState(input) {
  var opts = isObject(input) ? input : {}
  var now = isFinite(Number(opts.now)) ? Number(opts.now) : Date.now()
  var staleMs = clampInt(opts.staleAfterMin, DEFAULT_STALE_AFTER_MIN, 5, 1440) * 60000

  var status = isObject(opts.status) ? opts.status : null
  var stuckMs = effectiveStuckMin(opts.stuckAfterMin, statusFolderCount(status)) * 60000
  var run = runOf(status)
  var started = toMillis(run && run.started)
  var finished = toMillis(run && run.finished)
  var unfinished = isUnfinished(run)

  if (opts.installed !== true) {
    return { state: "unconfigured", detail: "gdrive-sync is not installed" }
  }
  if (intOr(opts.folderCount, 0) <= 0) {
    return { state: "unconfigured", detail: "No folders are configured" }
  }

  if (unfinished && started !== null && now - started <= stuckMs) {
    return { state: "syncing", detail: "A sync is running" }
  }

  if (isFailedExit(run)) {
    return { state: "error", detail: "The last run failed (exit " + Number(run.exit) + ")" }
  }
  if (hasFolderError(status)) {
    return { state: "error", detail: "A folder failed to sync" }
  }

  if (!run) {
    return { state: "stale", detail: "No sync has been recorded yet" }
  }
  if (unfinished) {
    return { state: "stale", detail: "A run started but never finished" }
  }
  if (finished === null) {
    return { state: "stale", detail: "The last run has no usable timestamp" }
  }
  if (now - finished > staleMs) {
    return { state: "stale", detail: "The last sync is older than expected" }
  }
  if (opts.timerActive === false) {
    return { state: "stale", detail: "The gdrive-sync timer is not active" }
  }

  if (lockWasHeld(run)) {
    return { state: "idle", detail: "The last run skipped: another was already going" }
  }
  return { state: "idle", detail: "Everything is in sync" }
}

function stateGlyph(state) {
  var key = str(state)
  return GLYPHS[key] !== undefined ? GLYPHS[key] : GLYPHS.idle
}

function stateLabel(state) {
  switch (str(state)) {
    case "unconfigured": return "Not set up"
    case "syncing": return "Syncing"
    case "error": return "Sync error"
    case "stale": return "Out of date"
    default: return "In sync"
  }
}

// Only `error` earns bar.urgent. An unconfigured or stale widget is dim, which
// says "look at me later" instead of "something broke".
function stateIsUrgent(state) { return str(state) === "error" }
function stateIsDim(state) {
  var key = str(state)
  return key === "unconfigured" || key === "stale"
}

// ------------------------------------------------------------- formatting

function formatDuration(ms) {
  var total = Number(ms)
  if (!isFinite(total) || total < 0) return ""
  var seconds = Math.round(total / 1000)
  if (seconds < 60) return seconds + "s"
  var minutes = Math.floor(seconds / 60)
  var restSeconds = seconds % 60
  if (minutes < 60) return restSeconds === 0 ? minutes + "m" : minutes + "m " + restSeconds + "s"
  var hours = Math.floor(minutes / 60)
  var restMinutes = minutes % 60
  return restMinutes === 0 ? hours + "h" : hours + "h " + restMinutes + "m"
}

function formatRelative(ms, now) {
  var at = Number(ms)
  var reference = isFinite(Number(now)) ? Number(now) : Date.now()
  if (!isFinite(at)) return "never"
  var diff = reference - at
  if (diff < 45000) return "just now"
  var minutes = Math.round(diff / 60000)
  if (minutes < 90) return minutes + " min ago"
  var hours = Math.round(diff / 3600000)
  if (hours < 36) return hours + " h ago"
  return Math.round(diff / 86400000) + " d ago"
}

function runDuration(status) {
  var run = runOf(status)
  var started = toMillis(run && run.started)
  var finished = toMillis(run && run.finished)
  if (started === null || finished === null || finished < started) return null
  return finished - started
}

function triggerLabel(status) {
  var run = runOf(status)
  switch (str(run && run.trigger)) {
    case "timer": return "timer"
    case "watch": return "watcher"
    case "manual": return "manual"
    default: return ""
  }
}

// Header of the popup: when the last run was, how long it took, what started
// it. A run still going says so instead of showing a duration it does not
// have yet.
function headerSummary(status, now) {
  var run = runOf(status)
  if (!run) return { title: "No sync recorded", meta: "" }

  var parts = []
  var trigger = triggerLabel(status)
  if (trigger !== "") parts.push(trigger)
  if (run.dryRun === true) parts.push("dry run")

  if (isUnfinished(run)) {
    var started = toMillis(run.started)
    if (started !== null) parts.unshift("started " + formatRelative(started, now))
    return { title: "Syncing now", meta: parts.join(" · ") }
  }

  var duration = runDuration(status)
  if (duration !== null) parts.push(formatDuration(duration))
  if (lockWasHeld(run)) parts.push("lock was held")

  var finished = toMillis(run.finished)
  return {
    title: finished === null ? "Last sync unknown" : "Synced " + formatRelative(finished, now),
    meta: parts.join(" · ")
  }
}

function folderGlyph(result) {
  var key = str(result)
  return FOLDER_GLYPHS[key] !== undefined ? FOLDER_GLYPHS[key] : FOLDER_GLYPHS.unknown
}

function resultRank(result) {
  var key = str(result)
  return RESULT_RANK[key] !== undefined ? RESULT_RANK[key] : RESULT_RANK.unknown
}

// One row per folder, exactly as status.json describes it, but ordered so the
// rows worth reading come first: error, skipped, in progress, then ok.
// `reason` carries whatever text the CLI already printed; the widget invents
// no vocabulary of its own.
//
// The sort is explicitly stable — the original index breaks every tie — so
// folders.txt order is preserved inside each group. Array.prototype.sort is
// only guaranteed stable in recent engines, and the QML engine is not a
// version this file gets to assume.
function folderRows(status) {
  var folders = isObject(status) ? status.folders : null
  var rows = []
  if (!isArray(folders)) return rows
  for (var i = 0; i < folders.length; i++) {
    var folder = isObject(folders[i]) ? folders[i] : {}
    var result = str(folder.result) || "unknown"
    rows.push({
      name: str(folder.name),
      result: result,
      reason: result === "ok" ? "" : str(folder.reason),
      glyph: folderGlyph(result),
      urgent: result === "error",
      at: str(folder.at),
      order: i,
      rank: resultRank(result)
    })
  }
  rows.sort(function(a, b) {
    return a.rank !== b.rank ? a.rank - b.rank : a.order - b.order
  })
  return rows
}

// "98 ok · 2 errors", and empty until the list is long enough that the eye
// cannot count it. Groups appear in the order the header should read them,
// and a group with no folders in it is left out entirely.
function folderSummary(status) {
  var folders = isObject(status) ? status.folders : null
  if (!isArray(folders) || folders.length <= FOLDER_SUMMARY_THRESHOLD) return ""

  var counts = { ok: 0, error: 0, skipped: 0, busy: 0, unknown: 0 }
  for (var i = 0; i < folders.length; i++) {
    var result = str(isObject(folders[i]) ? folders[i].result : "") || "unknown"
    if (result === "ok") counts.ok++
    else if (result === "error") counts.error++
    else if (result === "skipped") counts.skipped++
    else if (result === "running" || result === "initialising") counts.busy++
    else counts.unknown++
  }

  var parts = []
  if (counts.ok > 0) parts.push(counts.ok + " ok")
  if (counts.error > 0) parts.push(counts.error + (counts.error === 1 ? " error" : " errors"))
  if (counts.skipped > 0) parts.push(counts.skipped + " skipped")
  if (counts.busy > 0) parts.push(counts.busy + " in progress")
  if (counts.unknown > 0) parts.push(counts.unknown + " unknown")
  return parts.join(" \u00b7 ")
}

function watcherGlyph(state) {
  var key = str(state)
  return WATCHER_GLYPHS[key] !== undefined ? WATCHER_GLYPHS[key] : WATCHER_GLYPHS.unknown
}

// `stopped` is written on a clean exit, so a watcher file that says stopped is
// telling the truth rather than going stale. No watcher.json at all means the
// watcher is simply not part of this installation.
function watcherRow(watcher, now) {
  if (!isObject(watcher)) {
    return { present: false, state: "", label: "Watcher not running", glyph: watcherGlyph(""), pending: [], detail: "" }
  }
  var state = str(watcher.state) || "unknown"
  var pending = []
  if (isArray(watcher.pending)) {
    for (var i = 0; i < watcher.pending.length; i++) pending.push(str(watcher.pending[i]))
  }

  var label
  switch (state) {
    case "watching": label = "Watching for changes"; break
    case "pending": label = "Changes waiting to sync"; break
    case "syncing": label = "Watcher is syncing"; break
    case "retry": label = "Retrying after a failure"; break
    case "stopped": label = "Watcher stopped"; break
    default: label = "Watcher state unknown"; break
  }

  var detail = pending.length > 0 ? pending.join(", ") : ""
  if (state === "retry") {
    var nextRetry = toMillis(watcher.nextRetry)
    if (nextRetry !== null) {
      var wait = Math.max(0, Math.round((nextRetry - (isFinite(Number(now)) ? Number(now) : Date.now())) / 1000))
      detail = "next attempt in " + wait + "s" + (detail === "" ? "" : " · " + detail)
    }
  }

  return { present: true, state: state, label: label, glyph: watcherGlyph(state), pending: pending, detail: detail }
}

// -------------------------------------------------------------- commands
//
// Every one of these is handed to bar.run(), which is fire-and-forget: the
// shell process must never wait on rclone. "Sync now" goes through systemd so
// the unit keeps owning the run, the lock, and the exit-75 contract.

function syncCommand(profile) {
  if (!isProfileName(profile)) return ""
  return "systemctl --user start gdrive-sync@" + trim(profile) + ".service"
}

function timerUnit(profile) {
  if (!isProfileName(profile)) return ""
  return "gdrive-sync@" + trim(profile) + ".timer"
}

// Every instance in one argument list, so the number of processes the shell
// spawns stays at one however many accounts the user has.
function timerUnits(profiles) {
  var out = []
  if (!isArray(profiles)) return out
  for (var i = 0; i < profiles.length; i++) {
    var unit = timerUnit(profiles[i])
    if (unit !== "") out.push(unit)
  }
  return out
}

function openPathCommand(path) {
  var target = trim(path)
  if (target === "") return ""
  return "xdg-open " + shellQuote(target)
}

// Logs and folders.txt are text: prefer the editor the user picked in Omarchy
// and fall back to the desktop handler when that helper is not installed.
function openTextCommand(path) {
  var target = trim(path)
  if (target === "") return ""
  var quoted = shellQuote(target)
  return "if command -v omarchy-launch-editor >/dev/null 2>&1; then omarchy-launch-editor " + quoted +
    "; else xdg-open " + quoted + "; fi"
}

// gdrive-sync and gdrive-watch log to the journal and nowhere else: there is
// no log file and status.json carries no `log` field. Both tag their own
// output, so one reader covers the sync and the watcher at once, followed live
// in a terminal.
function journalCommand() {
  return "omarchy-launch-terminal bash -lc " +
    shellQuote("journalctl --user -t gdrive-sync -t gdrive-watch -f")
}

// The widget never installs anything. It opens a terminal with the command
// visible, so the user reads it and approves it.
function installCommand(pluginDir) {
  var dir = trim(pluginDir)
  if (dir === "") return ""
  var inner = "cd " + shellQuote(dir) + " && ./install.sh; echo; read -rsp 'Press enter to close' _"
  return "omarchy-launch-terminal bash -lc " + shellQuote(inner)
}

function editFoldersCommand(foldersPath) {
  return openTextCommand(foldersPath)
}

function timerActiveFromOutput(text) {
  return trim(text) === "active"
}

// `systemctl is-active a b` prints one word per unit, in the order asked, so
// the answer is read positionally. Output shorter than the list leaves the
// rest false: a timer systemd said nothing about is not a running one.
function timerActiveMap(text, profiles) {
  var lines = str(text).split(/\r?\n/)
  var words = []
  for (var i = 0; i < lines.length; i++) {
    var word = trim(lines[i])
    if (word !== "") words.push(word)
  }
  var map = {}
  if (!isArray(profiles)) return map
  for (var j = 0; j < profiles.length; j++) {
    map[str(profiles[j])] = j < words.length && words[j] === "active"
  }
  return map
}

// ------------------------------------------------------------------ exports

if (typeof module !== "undefined") {
  module.exports = {
    EXIT_LOCK_HELD: EXIT_LOCK_HELD,
    DEFAULT_CONF_ROOT: DEFAULT_CONF_ROOT,
    DEFAULT_STATE_ROOT: DEFAULT_STATE_ROOT,
    DEFAULT_STALE_AFTER_MIN: DEFAULT_STALE_AFTER_MIN,
    DEFAULT_STUCK_AFTER_MIN: DEFAULT_STUCK_AFTER_MIN,
    STUCK_PER_FOLDER_MIN: STUCK_PER_FOLDER_MIN,
    STUCK_CEILING_MIN: STUCK_CEILING_MIN,
    FOLDER_SUMMARY_THRESHOLD: FOLDER_SUMMARY_THRESHOLD,
    parseJson: parseJson,
    toMillis: toMillis,
    shellQuote: shellQuote,
    folderSpecs: folderSpecs,
    expandHome: expandHome,
    envValue: envValue,
    joinPath: joinPath,
    defaultConfRoot: defaultConfRoot,
    defaultStateRoot: defaultStateRoot,
    defaultLocalRoot: defaultLocalRoot,
    profileConfDir: profileConfDir,
    profileStateDir: profileStateDir,
    profileLocalRoot: profileLocalRoot,
    isProfileName: isProfileName,
    profilesFromOutput: profilesFromOutput,
    stateUrgency: stateUrgency,
    worstState: worstState,
    pluginDirFromUrl: pluginDirFromUrl,
    isUnfinished: isUnfinished,
    isFailedExit: isFailedExit,
    lockWasHeld: lockWasHeld,
    hasFolderError: hasFolderError,
    statusFolderCount: statusFolderCount,
    effectiveStuckMin: effectiveStuckMin,
    deriveState: deriveState,
    stateGlyph: stateGlyph,
    stateLabel: stateLabel,
    stateIsUrgent: stateIsUrgent,
    stateIsDim: stateIsDim,
    formatDuration: formatDuration,
    formatRelative: formatRelative,
    runDuration: runDuration,
    triggerLabel: triggerLabel,
    headerSummary: headerSummary,
    folderGlyph: folderGlyph,
    folderRows: folderRows,
    folderSummary: folderSummary,
    watcherGlyph: watcherGlyph,
    watcherRow: watcherRow,
    syncCommand: syncCommand,
    timerUnit: timerUnit,
    timerUnits: timerUnits,
    openPathCommand: openPathCommand,
    openTextCommand: openTextCommand,
    journalCommand: journalCommand,
    installCommand: installCommand,
    editFoldersCommand: editFoldersCommand,
    timerActiveFromOutput: timerActiveFromOutput,
    timerActiveMap: timerActiveMap
  }
}
