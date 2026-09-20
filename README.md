# appblock — Omarchy bar widget

Live [appblock](https://github.com/ArhamTheDeveloper/appblock) state in the
Omarchy bar: which apps are blocked right now, appblock's own enforcement label
for each, and live countdowns for timed blocks and pending cooldown lifts.

This plugin is a **display layer**. It runs `appblock list --json`, parses that
one document, and renders it.

## What it deliberately does not do

The boundary is the point of the plugin, so it is worth stating plainly:

- It **never** reimplements, duplicates, or approximates appblock's blocking or
  unblocking logic. appblock decides what is blocked; this widget asks.
- It **never** reads appblock's internals — no `blocked.list`, no
  `blocked-until.list`, no shim files, no `.desktop` entries. Those remain a
  human escape hatch, not an API. Reading them would mean two implementations of
  one truth, which is the bug class appblock's own README warns about.
- It **never** mutates state itself. The two controls it offers are handed
  straight back to the binary: `appblock unblock <app>` and a button that opens
  the real CLI. That terminal **stays open** at an interactive prompt after
  printing the current state — Omarchy's floating-terminal launcher runs its
  command inside a `bash -c` that exits when the command finishes, so the
  payload ends in `bash -i` rather than a bare `appblock list`.
- It offers **no faster unblock path than the CLI has.** Unblocking runs the
  real verb, `appblock unblock <app>`, with no `--after 0`, no `--cancel`, and
  no shortcut of any kind, so the request goes through the existing friction
  flow and is *scheduled* behind the normal cooldown (10m by default). The
  widget then shows that pending lift's countdown. A one-click instant unblock
  would defeat the entire point of the cooldown, so it deliberately does not
  exist here.
- It shows `enforcement` **verbatim**. appblock composes that string
  dynamically — `enforced`, `enforced, launcher masked (by-id launch
  intercepted)`, `web-app URL guard (keybind/launcher intercepted)`,
  `hidden only — target gone (…)`, `… (shim stale — refresh with 'appblock
  shims')` — so it is not an enum and is never mapped onto a fixed label set.
  The widget uses a coarse colour hint derived by substring, and always renders
  appblock's original sentence next to it.

## Requirements

- Omarchy with the Quickshell shell (`omarchy-shell`).
- `appblock` on `PATH`, or an absolute path to it via the `binary` setting.

## Install

```bash
omarchy plugin add https://github.com/ArhamTheDeveloper/omarchy-appblock.git --enable --yes
```

Or by hand:

```bash
git clone https://github.com/ArhamTheDeveloper/omarchy-appblock.git \
  ~/.config/omarchy/plugins/io.github.arhamthedeveloper.appblock
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.arhamthedeveloper.appblock
```

Plugins run as unsandboxed code inside `omarchy-shell`; read the source before
enabling, as with any plugin.

## Settings

Configured from the plugin's settings panel, or per-instance in
`~/.config/omarchy/shell.json`.

| Setting | Default | Notes |
|---|---|---|
| `binary` | `appblock` | Command or absolute path used to run appblock. |
| `refreshIntervalSec` | `30` | How often `appblock list --json` is re-read. Range 30–3600. |
| `showWhenNone` | `false` | Stay in the bar with a `0` count instead of hiding. |
| `glyph` | `` | Nerd Font glyph shown before the count. |

## How it refreshes

There is no daemon and no tight polling loop. The bar, the plugin, and this
widget all live inside the single already-running `omarchy-shell` process, so
the cost is one short-lived `appblock list --json` per interval:

- One `Process` re-runs `appblock list --json` on a wall-clock `Timer`
  (default 30s, user-tunable). `triggeredOnStart` covers the first paint.
- A local **1-second** tick drives the countdowns. It shells out to nothing —
  it subtracts the clock from the raw `until` / `unblock_at` epochs appblock
  already exported. That is why a 30s poll interval still gives a smooth
  countdown, and why the tick only runs while something is actually counting
  down. No duration parsing is reimplemented.
- Opening the panel, right-clicking the widget, or scrolling on it asks
  appblock again. A completed action also re-reads state rather than assuming it
  landed — which matters here, because `unblock` only *schedules* a lift, so the
  refresh is what reveals the pending-lift countdown.

## When it cannot read appblock

The widget fails visibly rather than showing something stale or wrong:

- A failed read (missing binary, non-zero exit, non-JSON output, empty stdout)
  **clears** the previous document and replaces it with an error banner naming
  the cause. Stale numbers are never left on screen looking live, and a failure
  never renders as "nothing is blocked".
- A read that does not finish within 10 seconds is terminated and reported as a
  timeout. The previous document is cleared, so a hung helper cannot leave stale
  counts looking live indefinitely.
- appblock is invoked **through `/bin/sh`**, so a missing binary is a real exit
  status 127 carrying a message — `appblock not found on PATH` — rather than a
  process that fails to spawn. Quickshell's `Process` exposes only `started` and
  `exited`, so a command that cannot be spawned never reports anything at all:
  the widget would sit blank and its in-flight flag would latch forever. That is
  the difference between a clear "not found" state and a silently empty widget.
- The bar glyph switches to a warning and the widget takes the urgent colour.
- `schema` is checked on every read. appblock calls the field `schema` (not
  `schema_version`) and bump-gates it; if it reports a version this widget does
  not understand, the widget says so and shows nothing, rather than guessing at
  a document shape it does not know. The panel header always shows the
  `schema` and appblock version currently in use.
- A structural surprise — a `blocked` entry without an `id` or without an
  `enforcement` label — is reported, not smoothed over.

## Interaction

| Input | Effect |
|---|---|
| Left click | Open/close the panel |
| Right click | Re-read appblock state |
| Scroll | Re-read appblock state |
| Panel row button | `appblock unblock <id>` (schedules the lift behind the cooldown) |
| Panel terminal button | Open a terminal running `appblock list`, then hand over an interactive shell |
| IPC | `omarchy-shell io.github.arhamthedeveloper.appblock cli` does the same |

## Tests

```bash
node tests/test_model.js
```

Covers the parsing contract: the schema gate (including the `schema` vs
`schema_version` trap), process-failure handling, structural validation of
`blocked` entries, the countdown arithmetic, duration formatting, and the
enforcement-label hints.

Validate the manifest against the shell's schema before publishing:

```bash
omarchy plugin validate .
```

## Development note

`omarchy plugin enable` / `rescanPlugins` and the shell's "Local plugin changed,
reloading" message do **not** re-instantiate an already-running bar widget. If
you edit `BarWidget.qml` and the change seems not to apply — a new IPC method
reporting "Function not found" while old ones still work is the tell — force a
real reload with `omarchy restart shell` (it refuses to run while the session is
locked, so it is safe). Verify which code is live by calling an IPC method that
only the new version defines.

## Layout

```
manifest.json   plugin manifest (schemaVersion 1, kind: bar-widget)
BarWidget.qml   the bar button, the single poll, the local countdown tick
Panel.qml       the popup: per-app rows, countdowns, toggle + CLI controls
Model.js        parsing, validation, countdown and label formatting (pure)
tests/          node tests for Model.js
```

`Model.js` has no QML dependencies, which is what makes it directly testable.

## License

MIT — see [LICENSE](LICENSE).
