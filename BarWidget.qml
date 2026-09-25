import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// appblock bar widget.
//
// Thin display/control layer. It runs `appblock list --json`, parses that one
// document, and renders it. It never inspects shim files, blocklist files, or
// desktop entries, and it never decides what "blocked" means. The two actions
// it offers are handed straight back to the appblock binary.
//
// Refresh shape: one Process re-run on a wall-clock Timer (30s default), never
// a tight loop. Countdowns tick locally once a second, but that is arithmetic
// on the epochs appblock already gave us - it shells out to nothing. So the
// steady-state cost is one short-lived `appblock list --json` per interval.
BarWidget {
  id: root
  moduleName: "io.github.arhamthedeveloper.launchbrake"

  // --- settings (declared in manifest barWidget.defaults / .schema) --------

  readonly property string binaryPath: {
    var v = root.setting("binary", Model.DEFAULT_BINARY)
    if (typeof v !== "string" || v.replace(/\s+/g, "") === "") return Model.DEFAULT_BINARY
    return v
  }

  readonly property int refreshSeconds: {
    var n = Number(root.setting("refreshIntervalSec", Model.DEFAULT_REFRESH_SEC))
    if (!isFinite(n) || n <= 0) return Model.DEFAULT_REFRESH_SEC
    return Math.max(Model.MIN_REFRESH_SEC, Math.min(Model.MAX_REFRESH_SEC, Math.round(n)))
  }

  readonly property bool showWhenNone: root.setting("showWhenNone", false) === true

  readonly property string blockedGlyph: {
    var g = root.setting("glyph", "\uf05e")
    return (typeof g === "string" && g !== "") ? g : "\uf05e"
  }

  // --- invoking appblock ---------------------------------------------------

  // Every appblock invocation goes through /bin/sh. Quickshell's Process only
  // emits started/exited, so a command that cannot be spawned never exits and
  // never reports anything - the widget would sit blank and its in-flight flag
  // would latch forever. A shell always starts, so a missing binary becomes a
  // real exit status 127 with a message on stderr, which is a state this widget
  // can display.
  readonly property string runViaShellScript:
      "bin=$1; shift\n"
    + "case $bin in\n"
    + "  */*) [ -x \"$bin\" ] || { echo \"appblock not found at $bin\" >&2; exit 127; } ;;\n"
    + "  *) command -v \"$bin\" >/dev/null 2>&1 || { echo \"appblock not found on PATH\" >&2; exit 127; } ;;\n"
    + "esac\n"
    + "exec \"$bin\" \"$@\"\n"

  function appblockCommand(args) {
    return ["/bin/sh", "-c", root.runViaShellScript, "appblock", root.binaryPath].concat(args)
  }

  // --- state ---------------------------------------------------------------

  // The parsed `appblock list --json` document, or null when it could not be
  // read. Cleared on every failure so a stale document is never shown as live.
  property var state: null
  // { error, hint } from the most recent failed read; null while healthy.
  property var errorView: null
  property bool querying: false
  // Wall clock in epoch seconds, ticked locally to drive countdowns.
  property double nowSec: Math.floor(Date.now() / 1000)
  // Set while an unblock request is in flight, so the panel can disable its controls.
  property bool busy: false
  property string actionError: ""

  readonly property bool failed: root.errorView !== null
  readonly property int blockedCount: Model.barCount(root.state)
  readonly property bool timed: Model.hasAnyDeadline(root.state)

  readonly property string glyph: root.failed ? "\uf071" : root.blockedGlyph

  readonly property string displayText: {
    if (root.failed) return root.vertical ? root.glyph : root.glyph + " appblock"
    if (root.state === null) return ""                                  // first read
    if (root.blockedCount === 0 && !root.showWhenNone) return ""
    return root.vertical ? root.glyph : root.glyph + " " + root.blockedCount
  }

  readonly property string tooltipText: {
    if (root.failed) {
      return "appblock: " + (root.errorView ? root.errorView.error : "could not read state")
    }
    if (root.state === null) return "appblock: reading state…"
    if (root.blockedCount === 0) return "appblock: nothing blocked"
    // Name, appblock's enforcement sentence verbatim, and the remaining time.
    var lines = [root.blockedCount + " blocked"]
    for (var i = 0; i < root.state.blocked.length && i < 5; i++) {
      var entry = root.state.blocked[i]
      var line = entry.id + " — " + entry.enforcement
      var left = Model.remainingSeconds(entry, root.nowSec)
      if (left !== null) line += " · " + Model.formatDuration(left) + " left"
      lines.push(line)
    }
    if (root.state.blocked.length > 5) lines.push("+" + (root.state.blocked.length - 5) + " more")
    return lines.join("\n")
  }

  // --- actions -------------------------------------------------------------

  // Re-read appblock's own state. The only way this widget learns anything.
  function refresh() {
    if (!queryProc.running) {
      queryProc.timedOut = false
      root.querying = true
      queryProc.running = true
    }
  }

  // Unblocking goes through the real CLI verb, with no extra flags: plain
  // `appblock unblock <id>` SCHEDULES the lift behind appblock's normal cooldown
  // (10m by default) exactly as typing it would. There is deliberately no
  // --after/--cancel here and no more convenient path: a bar that lifts a block
  // faster than the CLI would defeat the friction the cooldown exists to create.
  // While a lift is pending, the widget shows its countdown instead.
  function unblockApp(id) {
    if (typeof id !== "string" || id === "" || root.busy) return
    if (actionProc.running) return
    root.actionError = ""
    root.busy = true
    actionProc.pendingLabel = "unblock"
    actionProc.pendingTarget = id
    actionProc.command = root.appblockCommand(["unblock", id])
    actionProc.running = true
  }

  // Escape hatch for everything the bar does not model: open the real CLI.
  //
  // The terminal must OUTLIVE the command. The launcher splices its arguments
  // into `bash -c "omarchy-show-logo; <cmd>; ...; omarchy-show-done"`, so a
  // bare `appblock list` prints and the terminal closes immediately - useless
  // when the whole point is to keep typing appblock commands. Ending the
  // command with an interactive shell leaves the user at a prompt instead.
  function openCli() {
    if (!root.bar || typeof root.bar.run !== "function") {
      console.warn("appblock: no bar available to launch the CLI")
      return
    }
    // Show the current state first, then hand over a shell that stays open.
    var inner = shellQuote(root.binaryPath) + " list; echo; bash -i"
    root.bar.run("omarchy-launch-floating-terminal-with-presentation \""
      + escapeForDoubleQuotes(inner) + "\"")
  }

  // POSIX-quote one word for the terminal's shell.
  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  // The launcher receives our command inside a double-quoted `bash -c` string,
  // and the whole thing is handed to a shell by execDetached first, so `$`, 
  // backticks, `"` and `\` have to survive two rounds of expansion. Without
  // this, `$VAR` in the payload would be expanded too early (by the wrong shell)
  // or vanish entirely.
  function escapeForDoubleQuotes(text) {
    return String(text)
      .replace(/\\/g, "\\\\")
      .replace(/"/g, "\\\"")
      .replace(/\$/g, "\\$")
      .replace(/`/g, "\\`")
  }

  // --- panel plumbing (same shape as the Mushaf widget) --------------------

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function togglePanel() {
    root.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // Re-read appblock's live state on a sane cadence. Not a tight loop: one
  // process per interval, and `triggeredOnStart` covers the first paint.
  Timer {
    interval: root.refreshSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Local one-second tick for the countdowns. Runs only while something is
  // actually counting down, and never shells out - it exists so a 30s poll
  // interval still gives a smooth countdown, not so the widget can poll faster.
  Timer {
    interval: 1000
    running: root.timed
    repeat: true
    onTriggered: root.nowSec = Math.floor(Date.now() / 1000)
  }

  // A wedged filesystem/helper must not leave an old count looking live
  // forever. Stopping Process terminates the child; onExited recognizes this
  // as our timeout rather than replacing it with a generic signal exit error.
  Timer {
    interval: 10000
    running: queryProc.running
    repeat: false
    onTriggered: {
      queryProc.timedOut = true
      root.querying = false
      root.state = null
      root.errorView = {
        error: "appblock state query timed out after 10 seconds",
        hint: "Run `appblock list --json` in a terminal to diagnose the hang."
      }
      queryProc.running = false
    }
  }

  Process {
    id: queryProc
    running: false
    property bool timedOut: false
    command: root.appblockCommand(["list", "--json"])

    stdout: StdioCollector {
      id: queryStdout
      waitForEnd: true
    }

    stderr: StdioCollector {
      id: queryStderr
      waitForEnd: true
    }

    onExited: function(exitCode) {
      root.querying = false
      if (queryProc.timedOut) {
        queryProc.timedOut = false
        return
      }
      var result = Model.parseListOutput(queryStdout.text, exitCode, queryStderr.text)
      root.nowSec = Math.floor(Date.now() / 1000)
      if (result.ok) {
        root.state = result.state
        root.errorView = null
      } else {
        // Drop the previous document rather than leaving it on screen. Numbers
        // that stopped being true must not keep looking live.
        root.state = null
        root.errorView = { error: result.error, hint: result.hint }
      }
    }
  }

  Process {
    id: actionProc
    running: false
    property string pendingLabel: ""
    property string pendingTarget: ""

    stdout: StdioCollector {
      waitForEnd: true
    }

    stderr: StdioCollector {
      id: actionStderr
      waitForEnd: true
    }

    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var why = String(actionStderr.text || "").replace(/\s+$/, "")
        root.actionError = actionProc.pendingLabel + " " + actionProc.pendingTarget + " failed"
          + (why !== "" ? ": " + why.split("\n")[0] : "")
      } else {
        root.actionError = ""
      }
      root.busy = false
      // Never assume the action landed: ask appblock what is true now.
      root.refresh()
    }
  }

  IpcHandler {
    target: "io.github.arhamthedeveloper.launchbrake"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function refresh() { root.refresh() }
    function cli() { root.openCli() }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.displayText
    labelVisible: true
    hasVisualContent: root.displayText !== ""
    fixedHeight: -1
    horizontalMargin: 8.75
    verticalPadding: 8.75
    foreground: root.failed && root.bar ? root.bar.urgent : (root.bar ? root.bar.barForeground : Color.foreground)
    active: root.failed
    tooltipText: root.tooltipText

    onPressed: function(b) {
      if (b === Qt.LeftButton) root.togglePanel()
      else if (b === Qt.RightButton) root.refresh()
    }

    onWheelMoved: function(delta) {
      if (delta !== 0) root.refresh()
    }
  }
}
