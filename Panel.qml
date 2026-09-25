import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The appblock popup.
//
// Display-only, plus two controls that are handed straight back to the appblock
// binary: `appblock unblock <id>` verbatim, which SCHEDULES the lift behind
// appblock's normal cooldown, and "open CLI" for everything the bar does not
// model. There is deliberately no faster unblock path here - offering one would
// defeat the friction the cooldown exists to create. Nothing in this file
// mutates appblock state directly, and every value shown comes from the parsed
// `list --json` document.
Panel {
  id: root
  moduleName: "io.github.arhamthedeveloper.launchbrake"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color contentForeground: bar ? bar.barForeground : Color.foreground
  readonly property color mutedForeground: Color.muted
  readonly property color accentColor: Color.accent
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // All state comes from the host widget, which owns the single poll of
  // `appblock list --json`. The panel never runs appblock itself for reads.
  readonly property var state: hostWidget ? hostWidget.state : null
  readonly property var errorView: hostWidget ? hostWidget.errorView : null
  readonly property double nowSec: hostWidget ? hostWidget.nowSec : 0
  readonly property bool busy: hostWidget ? hostWidget.busy === true : false
  readonly property string actionError: hostWidget ? hostWidget.actionError : ""

  readonly property var entries: root.state && root.state.blocked ? root.state.blocked : []
  readonly property int blockedCount: root.entries.length
  readonly property int managedCount: root.state && root.state.managed ? root.state.managed.length : 0

  readonly property string chipLabel: root.errorView !== null
    ? "appblock !"
    : (root.state === null ? "appblock" : String(root.blockedCount))
  readonly property string tooltipLabel: "appblock"

  // The panel hugs its rows rather than always opening at a fixed size: the
  // list's laid-out content height plus the fixed chrome, clamped. Reading
  // `entryList.contentHeight` is safe here because a ListView's content height
  // depends on its width, never its own height - so this cannot feed back into
  // the list height that is derived from it.
  readonly property int panelChromeHeight: Style.space(30) + Style.space(16) + Style.space(58)
  readonly property int desiredContentHeight: {
    if (root.errorView !== null) return panelChromeHeight + Style.space(84)
    if (root.entries.length === 0) return panelChromeHeight + Style.space(24)
    var extra = root.actionError !== "" ? Style.space(30) : 0
    return Math.max(Style.space(190), panelChromeHeight + entryList.contentHeight + extra)
  }

  function open() {
    root.controller.show()
    // Whatever is on screen may be up to one interval old; the user opening the
    // panel is a good moment to ask appblock again.
    if (root.hostWidget) root.hostWidget.refresh()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(root.desiredContentHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: {
        if (root.hostWidget) root.hostWidget.refresh()
      }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) entryList.flick(dy * Style.space(12))
      }

      Column {
        anchors.fill: parent
        spacing: Style.space(10)

        // --- header -------------------------------------------------------
        Item {
          id: headerRow
          width: parent.width
          height: Style.space(30)

          Row {
            id: headerLeftRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            // Constrained against the action buttons on the right. Two items
            // anchored to opposite edges of one row overlap in the middle as
            // soon as their contents are wide enough to meet, so the left side
            // is bounded and its text elides instead.
            width: Math.max(0, headerRow.width - headerActionsRow.width - Style.space(8))
            spacing: Style.space(7)

            Text {
              id: headerGlyph
              anchors.verticalCenter: parent.verticalCenter
              text: root.errorView !== null ? "\uf071" : "\uf05e"
              color: root.errorView !== null ? root.urgentColor : root.accentColor
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(0, headerLeftRow.width - headerGlyph.width - headerLeftRow.spacing)
              spacing: Style.space(1)

              Text {
                width: parent.width
                text: "appblock"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: {
                  if (root.state === null) return "reading state…"
                  var v = root.state.version !== "" ? "appblock " + root.state.version : "appblock"
                  return v + " · schema " + root.state.schema
                }
                color: root.mutedForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }

          Row {
            id: headerActionsRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: implicitWidth
            spacing: Style.space(4)

            PanelActionButton {
              tooltipText: "Re-read appblock state"
              iconText: "\uf021"
              foreground: root.contentForeground
              onClicked: {
                if (root.hostWidget) root.hostWidget.refresh()
              }
            }

            PanelActionButton {
              tooltipText: "Open a terminal with the appblock CLI (stays open)"
              iconText: "\uf120"
              foreground: root.contentForeground
              onClicked: {
                if (root.hostWidget) root.hostWidget.openCli()
              }
            }

            PanelActionButton {
              tooltipText: "Close"
              iconText: "\uf00d"
              foreground: root.contentForeground
              onClicked: root.close()
            }
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.contentForeground
        }

        // --- failure banner ----------------------------------------------
        // Shown instead of the list. A failed read must look like a failed read,
        // never like "nothing is blocked".
        Rectangle {
          id: failBanner
          width: parent.width
          height: root.errorView !== null ? failColumn.implicitHeight + Style.space(14) : 0
          visible: root.errorView !== null
          radius: Style.cornerRadius
          color: Qt.rgba(root.urgentColor.r, root.urgentColor.g, root.urgentColor.b, 0.12)
          border.width: 1
          border.color: root.urgentColor

          Column {
            id: failColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(7)
            anchors.rightMargin: Style.space(7)
            spacing: Style.space(3)

            Text {
              width: parent.width
              text: "Cannot read appblock state"
              color: root.urgentColor
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Text {
              width: parent.width
              text: root.errorView ? root.errorView.error : ""
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              visible: root.errorView !== null && root.errorView.hint !== ""
              text: root.errorView ? root.errorView.hint : ""
              color: root.mutedForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }

        // --- action failure ----------------------------------------------
        Text {
          id: actionErrorText
          width: parent.width
          height: visible ? implicitHeight : 0
          visible: root.actionError !== ""
          text: root.actionError
          color: root.urgentColor
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // --- blocked list -------------------------------------------------
        Text {
          id: emptyText
          width: parent.width
          height: visible ? implicitHeight : 0
          visible: root.errorView === null && root.state !== null && root.blockedCount === 0
          text: "Nothing is blocked."
          color: root.mutedForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
        }

        ListView {
          id: entryList
          width: parent.width
          // Whatever is left after the fixed rows. Clamped, so a short panel
          // squeezes the list instead of handing Qt a negative height.
          height: Math.max(0, parent.height - headerRow.height - failBanner.height
            - actionErrorText.height - emptyText.height - footerRow.height - Style.space(60))
          clip: true
          visible: root.errorView === null
          spacing: Style.space(8)
          boundsBehavior: Flickable.StopAtBounds
          model: root.entries

          delegate: Item {
            required property var modelData
            width: entryList.width
            height: entryColumn.implicitHeight + Style.space(4)

            Column {
              id: entryColumn
              width: parent.width - unblockButton.width - Style.space(10)
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: modelData.id
                color: Model.isDegraded(modelData.enforcement) ? root.mutedForeground : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                // VERBATIM. appblock owns this sentence; the widget only shows it.
                width: parent.width
                text: modelData.enforcement
                color: root.mutedForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                height: visible ? implicitHeight : 0
                visible: text !== ""
                // Derived locally from the raw epochs appblock exported, so it
                // counts down every second without another call.
                text: Model.countdownLabel(modelData, root.nowSec)
                color: root.accentColor
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // Runs `appblock unblock <id>` verbatim - no --after, no --cancel,
            // nothing faster. The lift is scheduled behind appblock's normal
            // cooldown (10m by default) and its countdown appears above.
            PanelActionButton {
              id: unblockButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\uf09c"
              enabled: !root.busy
              foreground: root.contentForeground
              tooltipText: "appblock unblock " + modelData.id
                + " — schedules the lift behind appblock's cooldown (10m by default)"
              onClicked: {
                if (root.hostWidget) root.hostWidget.unblockApp(modelData.id)
              }
            }
          }
        }

        Item {
          id: footerRow
          width: parent.width
          height: Style.space(16)

          // Same opposite-edge hazard as the header: the left text is bounded
          // by whatever the right one needs, and the right one is capped to just
          // over half the row, so neither can ever land on top of the other.
          Text {
            id: footerLeftText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, footerRow.width - footerRightText.width - Style.space(8))
            text: {
              if (root.state === null) return ""
              var s = root.managedCount + " managed"
              if (root.blockedCount > 0 && !root.timed) s += " · no countdowns"
              return s
            }
            color: root.mutedForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            id: footerRightText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, Math.round(footerRow.width * 0.55))
            text: "appblock list --json"
            color: root.mutedForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
