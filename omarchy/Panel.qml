import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar button and popup for gdrive-sync, in one entry point, following
// omarchy.tailscale: an external tool, a status indicator, and a popup that
// offers a few safe actions.
//
// Colors come from `bar.foreground` and `bar.urgent`, so the widget follows
// whatever theme is active without a line of theme code of its own. Actions go
// through bar.run(), which is fire-and-forget; the shell process never waits
// on a sync.
Panel {
  id: root
  moduleName: "mhavo.gdrive-sync"
  ipcTarget: "mhavo.gdrive-sync"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool showLabel: service.setting("showLabel", false) === true

  readonly property color stateColor: Model.stateIsUrgent(service.syncState)
    ? urgent
    : (Model.stateIsDim(service.syncState) ? dim : foreground)
  readonly property color barStateColor: Model.stateIsUrgent(service.syncState)
    ? urgent
    : (Model.stateIsDim(service.syncState) ? Qt.darker(barForeground, 1.55) : barForeground)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    service.refresh()
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function handlePress(buttonCode) {
    // Middle click re-reads the slow sources; nothing here starts a sync by
    // accident.
    if (buttonCode === Qt.MiddleButton) service.refresh()
    else root.toggle()
  }

  function run(command) {
    var text = String(command || "")
    if (text === "" || !bar) return
    bar.run(text)
    root.close()
  }

  Service {
    id: service
    settings: root.settings
    // Panel.qml lives in <plugin>/omarchy/, so install.sh is one level up.
    pluginDir: Model.pluginDirFromUrl(Qt.resolvedUrl("."))
  }

  // --- bar button ------------------------------------------------------------

  // Icon-only is the default and gets BarIconButton's optical centering; the
  // labelled form is a plain WidgetButton, which sizes itself to its text.
  Loader {
    id: button
    sourceComponent: root.showLabel ? labelledButton : iconOnlyButton
  }

  Component {
    id: iconOnlyButton

    BarIconButton {
      bar: root.bar
      text: Model.stateGlyph(service.syncState)
      foreground: root.barStateColor
      tooltipText: Model.stateLabel(service.syncState) + " — " + service.detail
      onPressed: function(buttonCode) { root.handlePress(buttonCode) }
    }
  }

  Component {
    id: labelledButton

    WidgetButton {
      bar: root.bar
      text: Model.stateGlyph(service.syncState) + "  " + Model.stateLabel(service.syncState)
      foreground: root.barStateColor
      fontSize: Style.font.bodySmall
      tooltipText: service.detail
      onPressed: function(buttonCode) { root.handlePress(buttonCode) }
    }
  }

  // A running sync is the one state worth animating: it is the only one that
  // is expected to end on its own.
  SequentialAnimation {
    running: service.syncing
    loops: Animation.Infinite
    alwaysRunToEnd: true
    NumberAnimation { target: button; property: "opacity"; from: 1.0; to: 0.45; duration: 700; easing.type: Easing.InOutQuad }
    NumberAnimation { target: button; property: "opacity"; from: 0.45; to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
    onRunningChanged: if (!running) button.opacity = 1.0
  }

  // --- popup -----------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s" || t === "S") { if (!service.unconfigured) root.run(service.syncNowCommand()) }
        else if (t === "o" || t === "O") root.run(service.openFolderCommand())
        else if (t === "l" || t === "L") root.run(service.openLogCommand())
        else if (t === "r" || t === "R") service.refresh()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(10)

          // Header: what the last run did, when, and what started it.
          PanelHero {
            width: parent.width
            title: service.unconfigured ? "Google Drive" : service.header.title
            meta: service.unconfigured ? "Not set up" : service.header.meta
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: Model.stateGlyph(service.syncState)
                color: root.stateColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: service.detail
            visible: text !== ""
            color: Model.stateIsUrgent(service.syncState) ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // --- unconfigured: say what to run, run nothing ----------------------

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: service.unconfigured

            PanelSeparator { foreground: root.foreground }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "gdrive-sync is not installed or has no folders to sync. The widget installs "
                + "nothing itself; run the installer and pick your folders."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            ActionRow {
              width: parent.width
              glyph: "󰆍"                        // md-console
              label: "Run ./install.sh in a terminal"
              onActivated: root.run(service.installCommand())
            }

            ActionRow {
              width: parent.width
              glyph: "󰏫"                        // md-pencil
              label: "Edit folders.txt"
              onActivated: root.run(service.editFoldersCommand())
            }
          }

          // --- folders ---------------------------------------------------------

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: !service.unconfigured && service.folderRows.length > 0

            PanelSeparator { foreground: root.foreground }

            // With more folders than fit one glance the header carries the
            // counts too; the rows themselves all stay in the list below.
            Item {
              width: parent.width
              implicitHeight: foldersHeader.implicitHeight

              PanelSectionHeader {
                id: foldersHeader
                anchors.left: parent.left
                anchors.top: parent.top
                text: "Folders"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              PanelSectionHeader {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.left: foldersHeader.right
                anchors.leftMargin: Style.space(8)
                horizontalAlignment: Text.AlignRight
                text: service.folderSummary
                visible: text !== ""
                foreground: root.foreground
                fontFamily: root.fontFamily
                elide: Text.ElideRight
              }
            }

            Repeater {
              model: service.folderRows

              Item {
                required property var modelData
                width: column.width
                implicitHeight: folderLabels.implicitHeight

                Text {
                  id: folderGlyph
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.top: parent.top
                  text: modelData.glyph
                  color: modelData.urgent ? root.urgent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                }

                Column {
                  id: folderLabels
                  anchors.left: folderGlyph.right
                  anchors.leftMargin: Style.space(8)
                  anchors.right: parent.right
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: modelData.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }

                  // The CLI's own words, not a taxonomy invented here.
                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: modelData.reason
                    visible: text !== ""
                    color: modelData.urgent ? root.urgent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }
              }
            }
          }

          // --- watcher ---------------------------------------------------------

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: !service.unconfigured && service.watcherRow.present

            PanelSeparator { foreground: root.foreground }

            Item {
              width: parent.width
              implicitHeight: watcherLabels.implicitHeight

              Text {
                id: watcherGlyph
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.top: parent.top
                text: service.watcherRow.glyph
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.icon
              }

              Column {
                id: watcherLabels
                anchors.left: watcherGlyph.right
                anchors.leftMargin: Style.space(8)
                anchors.right: parent.right
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: service.watcherRow.label
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: service.watcherRow.detail
                  visible: text !== ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }
            }
          }

          // --- actions ---------------------------------------------------------
          //
          // Nothing destructive lives here: --resync, --repin and enabling or
          // disabling units stay in the CLI, where the consequences are visible.

          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: !service.unconfigured

            PanelSeparator { foreground: root.foreground }

            // systemd owns the run, so the lock and the exit-75 contract keep
            // working exactly as they do for the timer.
            ActionRow {
              width: parent.width
              glyph: "󰓦"                        // md-sync
              label: "Sync now"
              hint: "s"
              onActivated: root.run(service.syncNowCommand())
            }

            ActionRow {
              width: parent.width
              glyph: "󰝰"                        // md-folder_open
              label: "Open folder"
              hint: "o"
              onActivated: root.run(service.openFolderCommand())
            }

            // No log file exists any more: both units write to the journal,
            // each under its own identifier, and this follows them together.
            ActionRow {
              width: parent.width
              glyph: "󰈙"                        // md-file_document
              label: "Follow log"
              hint: "l"
              onActivated: root.run(service.openLogCommand())
            }

            // --- configuration -------------------------------------------------

            PanelSeparator { foreground: root.foreground }

            ActionRow {
              width: parent.width
              glyph: "󰏫"                        // md-pencil
              label: "Edit folders.txt"
              hint: "f"
              onActivated: root.run(service.editFoldersCommand())
            }

            ActionRow {
              width: parent.width
              glyph: "󰈲"                        // md-filter
              label: "Edit filter.txt"
              hint: "t"
              onActivated: root.run(service.editFilterCommand())
            }

            // Only once the file exists. Opening a missing config.env in an
            // editor would create it on save with the default umask and none of
            // the guidance in examples/config.env; install.sh copies the example
            // and sets the permissions to 600.
            ActionRow {
              width: parent.width
              visible: service.configExists
              glyph: "󰒓"                        // md-cog
              label: "Edit config.env"
              hint: "c"
              onActivated: root.run(service.editConfigCommand())
            }

            Text {
              width: parent.width
              visible: !service.configExists
              textFormat: Text.PlainText
              text: "No config.env — the defaults apply. Copy examples/config.env into "
                + "the config directory to change the remote name or the paths."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }
  }

  // One row of the popup's action list: a glyph, a label, an optional keyboard
  // hint. Kept inline because it is three rows in one file, not a component
  // anything else needs.
  component ActionRow: Item {
    id: actionRow

    property string glyph: ""
    property string label: ""
    property string hint: ""
    property bool enabled: true

    signal activated()

    implicitHeight: Math.max(Style.spacing.popupRowHeight, actionLabel.implicitHeight + Style.space(8))

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: actionArea.containsMouse && actionRow.enabled
        ? Style.hoverFillFor(root.foreground, Color.accent)
        : "transparent"
      Behavior on color { ColorAnimation { duration: 60 } }
    }

    Text {
      id: actionGlyph
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
      text: actionRow.glyph
      color: actionRow.enabled ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }

    Text {
      id: actionLabel
      textFormat: Text.PlainText
      anchors.left: actionGlyph.right
      anchors.leftMargin: Style.space(8)
      anchors.right: actionHint.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: actionRow.label
      color: actionRow.enabled ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Text {
      id: actionHint
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.rightMargin: Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
      text: actionRow.hint
      visible: text !== ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: actionArea
      anchors.fill: parent
      hoverEnabled: true
      enabled: actionRow.enabled
      cursorShape: actionRow.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: actionRow.activated()
    }
  }
}
