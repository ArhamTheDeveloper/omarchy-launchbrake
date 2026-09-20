#!/usr/bin/env node
"use strict";

// Tests for Model.js - the parser/formatter behind the appblock bar widget.
//
// Model.js is a QML `.pragma library`, so it is loaded here the same way the
// Mushaf plugin's tests load its model: strip the QML-only directives and run
// the rest in a vm sandbox. That keeps Model.js free of QML constructs and lets
// the parsing contract be tested without a running shell.

const fs = require("fs");
const path = require("path");
const vm = require("vm");

function load(name) {
  const src = fs.readFileSync(path.join(__dirname, "..", name), "utf8")
    .split("\n")
    .filter((l) => !l.trim().startsWith(".pragma") && !l.trim().startsWith(".import"))
    .join("\n");
  const sandbox = { console };
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox, { filename: name });
  return sandbox;
}

const M = load("Model.js");

let pass = 0;
let fail = 0;
function ok(name, cond) {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name); }
}
function section(title) { console.log("\n# " + title); }

// A document shaped exactly like this machine's live `appblock list --json`.
const LIVE = JSON.stringify({
  schema: 1,
  version: "0.2.0",
  state_dir: "/home/u/.local/share/appblock",
  count: 2,
  blocked: [
    { id: "ferdium", enforcement: "enforced, launcher masked (by-id launch intercepted)",
      until: null, unblock_at: null, until_in: null, unblock_in: null },
    { id: "org.remmina.Remmina", enforcement: "enforced, launcher masked (by-id launch intercepted)",
      until: null, unblock_at: null, until_in: null, unblock_in: null }
  ],
  managed: ["rmpc", "chromium", "firefox", "ferdium", "remmina"]
});

// --- happy path ------------------------------------------------------------

section("well-formed document");

{
  const r = M.parseListOutput(LIVE, 0, "");
  ok("live document parses", r.ok === true);
  ok("schema recorded", r.state.schema === 1);
  ok("version recorded", r.state.version === "0.2.0");
  ok("two blocked entries", r.state.blocked.length === 2);
  ok("managed list kept", r.state.managed.length === 5);
  ok("enforcement kept verbatim", r.state.blocked[0].enforcement === "enforced, launcher masked (by-id launch intercepted)");
  ok("count helper agrees", M.barCount(r.state) === 2);
  ok("unsigned deadlines stay null", r.state.blocked[0].until === null && r.state.blocked[0].unblock_at === null);
  ok("no deadlines pending", M.hasAnyDeadline(r.state) === false);
}

// --- schema gating ---------------------------------------------------------

section("schema version gating");

{
  // The naming trap: appblock calls it `schema`, not `schema_version`. A
  // document carrying only `schema_version` must be rejected, not half-read.
  const doc = JSON.stringify({ schema_version: 1, blocked: [], managed: [] });
  const r = M.parseListOutput(doc, 0, "");
  ok("`schema_version` is not accepted as `schema`", r.ok === false);
  ok("names the missing field", /schema/.test(r.error));
  ok("no state leaked on failure", r.state === null);
}

{
  const doc = JSON.stringify({ schema: 2, version: "9.9.9", blocked: [], managed: [] });
  const r = M.parseListOutput(doc, 0, "");
  ok("future schema is refused", r.ok === false);
  ok("error names both versions", /schema 2/.test(r.error) && /understands 1/.test(r.error));
  ok("hint tells the user what to do", /[Uu]pdate/.test(r.hint));
  ok("state is null rather than guessed", r.state === null);
}

{
  const doc = JSON.stringify({ version: "0.2.0", blocked: [], managed: [] });
  const r = M.parseListOutput(doc, 0, "");
  ok("missing schema is refused", r.ok === false && r.state === null);
}

// --- malformed / partial documents -----------------------------------------

section("structural surprises are reported, not smoothed over");

const badDocs = [
  ["blocked missing", { schema: 1, managed: [] }],
  ["blocked not an array", { schema: 1, blocked: {}, managed: [] }],
  ["entry not an object", { schema: 1, blocked: ["ferdium"], managed: [] }],
  ["entry without id", { schema: 1, blocked: [{ enforcement: "enforced" }], managed: [] }],
  ["entry with empty id", { schema: 1, blocked: [{ id: "", enforcement: "enforced" }], managed: [] }],
  ["entry without enforcement", { schema: 1, blocked: [{ id: "ferdium" }], managed: [] }],
  ["root is an array", [{ schema: 1 }]],
  ["root is a string", "nope"]
];

for (const [label, doc] of badDocs) {
  const r = M.parseListOutput(JSON.stringify(doc), 0, "");
  ok("refused: " + label, r.ok === false && r.state === null && r.error !== "");
}

// --- process failures ------------------------------------------------------

section("process failures");

{
  // Bare 127 with nothing on stderr still has to read as "not installed".
  const r = M.parseListOutput("", 127, "");
  ok("exit 127 reads as not installed", r.ok === false && /not found/.test(r.error));
  ok("hint mentions the binary setting", /binary/.test(r.hint));
  ok("127 clears state rather than showing blank", r.state === null);
}
{
  // What the widget's /bin/sh wrapper actually emits when the binary is absent:
  // a real exit status with a message, because a Process that cannot be spawned
  // would never exit at all and the widget would sit blank forever.
  const r = M.parseListOutput("", 127, "appblock not found on PATH\n");
  ok("127 surfaces the shell's message", r.ok === false && r.error === "appblock not found on PATH");
  ok("127 is not mistaken for a parse failure", !/JSON/.test(r.error));
}

{
  const r = M.parseListOutput("", 2, "appblock: unknown option for list\nmore noise");
  ok("non-zero exit is an error", r.ok === false);
  ok("error carries the exit status", /status 2/.test(r.error));
  ok("stderr first line is surfaced", /unknown option for list/.test(r.error));
  ok("only the first stderr line is used", !/more noise/.test(r.error));
}

{
  const r = M.parseListOutput("", 0, "");
  ok("empty stdout is an error", r.ok === false && r.state === null);
}

{
  const r = M.parseListOutput("appblock: boom\n", 0, "chatter");
  ok("non-JSON stdout is an error", r.ok === false);
  ok("a snippet of the bad output is shown", /boom/.test(r.hint));
}

{
  // stdout must stay a clean document even when reconcile() narrates on stderr.
  const r = M.parseListOutput(LIVE, 0, "unblocked ferdium (cooldown elapsed)\n");
  ok("stderr narration does not disturb parsing", r.ok === true && r.state.blocked.length === 2);
}

// --- countdowns ------------------------------------------------------------

section("countdowns are arithmetic on appblock's raw epochs");

{
  const now = 1000;
  const doc = { schema: 1, blocked: [
    { id: "timed", enforcement: "enforced", until: now + 1200, unblock_at: null, until_in: 1200, unblock_in: null }
  ], managed: [] };
  const r = M.parseListOutput(JSON.stringify(doc), 0, "");
  ok("timed block parses", r.ok === true);
  ok("isTimed true", M.isTimed(r.state.blocked[0]) === true);
  ok("remaining derives from the epoch", M.remainingSeconds(r.state.blocked[0], now) === 1200);
  ok("remaining shrinks as the clock moves", M.remainingSeconds(r.state.blocked[0], now + 1150) === 50);
  ok("remaining floors at zero", M.remainingSeconds(r.state.blocked[0], now + 99999) === 0);
  ok("hasAnyDeadline true", M.hasAnyDeadline(r.state) === true);
  ok("label reads as a block lift", M.countdownLabel(r.state.blocked[0], now) === "block lifts in 20m 00s");
  ok("expired label switches", M.countdownLabel(r.state.blocked[0], now + 99999) === "block lifting now");
}

{
  const now = 5000;
  const doc = { schema: 1, blocked: [
    { id: "cooling", enforcement: "enforced", until: null, unblock_at: now + 591, until_in: null, unblock_in: 591 }
  ], managed: [] };
  const r = M.parseListOutput(JSON.stringify(doc), 0, "");
  ok("pending lift parses", r.ok === true);
  ok("pending lift label", M.countdownLabel(r.state.blocked[0], now) === "unblock lifts in 9m 51s");
  ok("countdown is labelled as an unblock", /unblock/.test(M.countdownLabel(r.state.blocked[0], now)));
}

{
  // Both deadlines present: the sooner one is what the user is waiting for.
  const now = 0;
  const entry = { id: "both", enforcement: "enforced", until: 3600, unblock_at: 60 };
  ok("soonest deadline wins", M.nextDeadline(entry).kind === "unblock");
  ok("remaining follows the soonest", M.remainingSeconds(entry, now) === 60);
}

{
  const entry = { id: "flat", enforcement: "enforced", until: null, unblock_at: null };
  ok("no deadlines reads null", M.nextDeadline(entry) === null);
  ok("no countdown label", M.countdownLabel(entry, 0) === "");
  ok("hasAnyDeadline false for flat state", M.hasAnyDeadline({ blocked: [entry] }) === false);
}

section("duration formatting");

ok("seconds only", M.formatDuration(45) === "45s");
ok("minutes and seconds are padded", M.formatDuration(591) === "9m 51s");
ok("hours drop seconds", M.formatDuration(5400) === "1h 30m");
ok("zero", M.formatDuration(0) === "0s");
ok("negative is clamped", M.formatDuration(-5) === "0s");
ok("non-numeric is clamped", M.formatDuration("junk") === "0s");

// --- enforcement labels -----------------------------------------------------

section("enforcement is displayed, not classified");

{
  const cases = [
    ["enforced", "enforced"],
    ["enforced, launcher masked (by-id launch intercepted)", "enforced"],
    ["web-app URL guard (keybind/launcher intercepted)", "web"],
    ["enforced (shim stale - refresh with 'appblock shims')", "degraded"],
    ["hidden only - target gone (re-run 'appblock block x' to refresh)", "degraded"],
    ["launcher masked (by-id launch intercepted)", "masked"],
    ["something appblock invents later", "unknown"]
  ];
  for (const [label, expected] of cases) {
    ok("severity hint: " + JSON.stringify(label), M.severityOf(label) === expected);
  }
  // The important part: an unknown label must still be displayable, and the
  // hint must never be used as the label itself.
  ok("unknown labels are not degraded", M.isDegraded("something appblock invents later") === false);
  ok("degraded detection", M.isDegraded("hidden only - target gone") === true);
}

// --- managed list -----------------------------------------------------------

section("managed list");

{
  const doc = { schema: 1, blocked: [], managed: ["a", "", "b", 7, null] };
  const r = M.parseListOutput(JSON.stringify(doc), 0, "");
  ok("non-string managed entries are dropped", r.state.managed.length === 2);
  ok("empty managed list is fine", r.state.blocked.length === 0);
  ok("barCount on empty state", M.barCount(r.state) === 0);
}

console.log("\n" + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
