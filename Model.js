.pragma library

// ---------------------------------------------------------------------------
// appblock bar widget - parsing and formatting only.
//
// THIN-LAYER BOUNDARY. Every value this file produces is derived from the JSON
// document that `appblock list --json` prints on stdout. Nothing here reads
// shim files, blocklist files, `until` files, or desktop entries, and nothing
// here decides what "blocked" means - appblock decides, and says so in the
// document. Do not add a second implementation of appblock's rules here; that
// is the exact bug class this widget exists to avoid.
//
// The same file is loaded by tests/test_model.js under plain node, so keep it
// free of QML-only constructs.
// ---------------------------------------------------------------------------

// The contract version this widget understands. appblock emits `schema`
// (NOT `schema_version`) on the top-level document and bump-gates it, so a
// mismatch is a hard stop here rather than a guess.
var SUPPORTED_SCHEMA = 1

var DEFAULT_BINARY = "appblock"
var DEFAULT_REFRESH_SEC = 30
var MIN_REFRESH_SEC = 30
var MAX_REFRESH_SEC = 3600

// --- result constructors ---------------------------------------------------

function okResult(state) {
  return { ok: true, state: state, error: "", hint: "" }
}

function failResult(error, hint) {
  return {
    ok: false,
    state: null,
    error: String(error === undefined || error === null ? "unknown error" : error),
    hint: String(hint === undefined || hint === null ? "" : hint)
  }
}

function numberOrNull(value) {
  if (value === null || value === undefined) return null
  var n = Number(value)
  return isFinite(n) ? n : null
}

function firstLine(text) {
  var s = String(text === undefined || text === null ? "" : text).replace(/\s+$/, "")
  if (s === "") return ""
  var i = s.indexOf("\n")
  return i === -1 ? s : s.slice(0, i)
}

// --- document parsing ------------------------------------------------------

// Parse the result of one `appblock list --json` run.
//
// `raw` is stdout, `exitCode` the process status, and `stderrText` stderr -
// which appblock deliberately uses for reconcile() narration while keeping
// stdout a clean JSON document. stderr is surfaced as a diagnostic only; it is
// never parsed for state.
function parseListOutput(raw, exitCode, stderrText) {
  var code = (exitCode === null || exitCode === undefined) ? 0 : Number(exitCode)
  var text = String(raw === undefined || raw === null ? "" : raw)

  if (code === 127) {
    // The widget runs appblock through /bin/sh precisely so a missing binary
    // lands here, as a real exit status with a message, rather than as a
    // process that never starts and therefore never exits.
    var missing = firstLine(stderrText)
    return failResult(missing !== "" ? missing : "appblock was not found",
      "Install appblock, or set this widget's `binary` setting to its path.")
  }
  if (code !== 0) {
    var why = firstLine(stderrText)
    return failResult("appblock exited with status " + code + (why ? ": " + why : ""),
      "Run `appblock list --json` in a terminal to see the full error.")
  }

  var trimmed = text.replace(/^\s+/, "").replace(/\s+$/, "")
  if (trimmed === "") {
    return failResult("appblock printed nothing",
      "`appblock list --json` should print one JSON document on stdout.")
  }

  var doc = null
  try {
    doc = JSON.parse(trimmed)
  } catch (e) {
    doc = null
  }
  if (doc === null) {
    return failResult("appblock output was not JSON",
      "Expected one JSON document on stdout, got: " + firstLine(trimmed).slice(0, 120))
  }

  return parseDocument(doc)
}

// Validate a decoded document. A structural surprise is reported, never papered
// over: a half-understood document is precisely the "shows the wrong thing
// confidently" failure this widget must not have.
function parseDocument(doc) {
  if (!doc || typeof doc !== "object" || Object.prototype.toString.call(doc) === "[object Array]") {
    return failResult("appblock output was not a JSON object", "")
  }

  var schema = numberOrNull(doc.schema)
  if (schema === null) {
    return failResult("appblock output has no `schema` field",
      "This widget reads the top-level `schema` field to know how to read the document. Note appblock calls it `schema`, not `schema_version`.")
  }
  if (schema !== SUPPORTED_SCHEMA) {
    return failResult(
      "appblock reports schema " + schema + ", this widget understands " + SUPPORTED_SCHEMA,
      "Update the appblock widget so the two agree. Nothing is shown rather than guessing at a document shape this widget does not know.")
  }

  if (!isArray(doc.blocked)) {
    return failResult("appblock output has no `blocked` array", "")
  }

  var blocked = []
  for (var i = 0; i < doc.blocked.length; i++) {
    var entry = doc.blocked[i]
    if (!entry || typeof entry !== "object") {
      return failResult("`blocked[" + i + "]` is not an object", "")
    }
    if (typeof entry.id !== "string" || entry.id === "") {
      return failResult("`blocked[" + i + "]` has no string id", "")
    }
    if (typeof entry.enforcement !== "string") {
      return failResult("`blocked[" + i + "]` (" + entry.id + ") has no enforcement label",
        "`enforcement` is appblock's own verdict on that app; without it there is nothing honest to display.")
    }
    blocked.push({
      id: entry.id,
      // Rendered verbatim and never mapped onto a fixed label set: appblock
      // composes this string dynamically, so any words added on our side would
      // be an interpretation of our own.
      enforcement: entry.enforcement,
      // Raw epoch deadlines - the authoritative values. `until_in` /
      // `unblock_in` are only the seconds remaining as of the call, so the
      // epochs are what the local countdown is derived from.
      until: numberOrNull(entry.until),
      unblock_at: numberOrNull(entry.unblock_at)
    })
  }

  var managed = []
  if (isArray(doc.managed)) {
    for (var j = 0; j < doc.managed.length; j++) {
      if (typeof doc.managed[j] === "string" && doc.managed[j] !== "") managed.push(doc.managed[j])
    }
  }

  return okResult({
    schema: schema,
    version: typeof doc.version === "string" ? doc.version : "",
    stateDir: typeof doc.state_dir === "string" ? doc.state_dir : "",
    blocked: blocked,
    managed: managed
  })
}

function isArray(value) {
  return Object.prototype.toString.call(value) === "[object Array]"
}

// --- countdowns ------------------------------------------------------------

// appblock exports the raw deadlines as epochs plus a seconds-remaining field,
// precisely so a widget can count down live without re-implementing duration
// parsing. Between polls the widget subtracts the clock from these epochs:
// arithmetic for display, not a second opinion about appblock's state.

function deadlines(entry) {
  var out = []
  if (entry && entry.until !== null && entry.until !== undefined) {
    out.push({ kind: "until", at: entry.until })
  }
  if (entry && entry.unblock_at !== null && entry.unblock_at !== undefined) {
    out.push({ kind: "unblock", at: entry.unblock_at })
  }
  return out
}

// The soonest of the entry's deadlines, or null when the block is indefinite.
function nextDeadline(entry) {
  var all = deadlines(entry)
  if (all.length === 0) return null
  var soonest = all[0]
  for (var i = 1; i < all.length; i++) {
    if (all[i].at < soonest.at) soonest = all[i]
  }
  return soonest
}

function isTimed(entry) {
  return nextDeadline(entry) !== null
}

// Seconds until the soonest deadline, floored at 0. Returns null when the entry
// has no deadline at all.
function remainingSeconds(entry, nowSec) {
  var deadline = nextDeadline(entry)
  if (deadline === null) return null
  var now = isFinite(Number(nowSec)) ? Number(nowSec) : Math.floor(Date.now() / 1000)
  return Math.max(0, Math.round(deadline.at - now))
}

function hasAnyDeadline(state) {
  if (!state || !isArray(state.blocked)) return false
  for (var i = 0; i < state.blocked.length; i++) {
    if (isTimed(state.blocked[i])) return true
  }
  return false
}

function pad2(n) {
  return n < 10 ? "0" + n : String(n)
}

function formatDuration(totalSeconds) {
  var s = Number(totalSeconds)
  if (!isFinite(s) || s < 0) s = 0
  s = Math.round(s)
  var hours = Math.floor(s / 3600)
  var minutes = Math.floor((s % 3600) / 60)
  var seconds = s % 60
  if (hours > 0) return hours + "h " + pad2(minutes) + "m"
  if (minutes > 0) return minutes + "m " + pad2(seconds) + "s"
  return seconds + "s"
}

// Human countdown for an entry's soonest deadline, e.g. "unblock lifts in 9m 31s".
function countdownLabel(entry, nowSec) {
  var deadline = nextDeadline(entry)
  if (deadline === null) return ""
  var left = remainingSeconds(entry, nowSec)
  var isLift = deadline.kind === "unblock"
  if (left <= 0) return isLift ? "unblock due now" : "block lifting now"
  return (isLift ? "unblock lifts in " : "block lifts in ") + formatDuration(left)
}

// --- enforcement labels ----------------------------------------------------

// appblock composes `enforcement` dynamically, e.g.
//   "enforced"
//   "enforced, launcher masked (by-id launch intercepted)"
//   "web-app URL guard (keybind/launcher intercepted)"
//   "enforced (shim stale - refresh with 'appblock shims')"
//   "hidden only - target gone (re-run 'appblock block <bin>' to refresh)"
// so this is a COARSE HINT for colour and ordering only. It is never rendered
// as appblock's verdict; the verbatim string is what the user sees.
function severityOf(enforcement) {
  var t = String(enforcement === undefined || enforcement === null ? "" : enforcement).toLowerCase()
  if (t.indexOf("hidden only") !== -1) return "degraded"
  if (t.indexOf("stale") !== -1) return "degraded"
  if (t.indexOf("web-app") !== -1) return "web"
  if (t.indexOf("launcher masked") !== -1 && t.indexOf("enforced") === -1) return "masked"
  if (t.indexOf("enforced") !== -1) return "enforced"
  return "unknown"
}

// True when the enforcement label itself admits the app is not actually
// launch-enforced right now - worth flagging in the panel, in appblock's words.
function isDegraded(enforcement) {
  return severityOf(enforcement) === "degraded"
}

// --- bar label -------------------------------------------------------------

function barCount(state) {
  return state && isArray(state.blocked) ? state.blocked.length : 0
}
