import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Silence - per-workspace audio controls.
// Owns writes to the state file consumed by the workspace-audio daemon:
//   $XDG_RUNTIME_DIR/workspace-audio/state.json
//
// Data flow is one-directional: the FILE is the only source of truth for
// rendering. Interactions record a small `desired` overlay (Tailscale-style,
// see Ui/ToggleSwitch.qml notes) so knobs react instantly, and every entry in
// it is dropped once the file round-trips back with the same value.
Panel {
  id: root

  moduleName: "salted.silence"
  ipcTarget: ""
  manageIpc: false

  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") + "/workspace-audio"
  readonly property string statePath: runtimeDir + "/state.json"

  // ---- file truth ----
  property var state: ({ autoMute: true, workspaces: {} })
  // ---- our unconfirmed intents: { "<wsId>": {muted?, volume?}, _auto: bool } ----
  property var desired: ({})

  property var workspaces: []   // [{id, name}] from hyprctl
  property var focusedIds: []   // active workspace id per monitor

  // Bar chrome, guarded: `bar` is briefly null while the panel mounts/unmounts.
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string ff: bar ? bar.fontFamily : "sans-serif"

  // ---------- reading ----------
  // Content always arrives through the shared descriptor-safe helper
  // (bin/read-state.py: O_NOFOLLOW|O_NONBLOCK open, fstat-validated, bounded
  // 64 KiB). A plain cat/FileView could block or exhaust the shell on a
  // planted FIFO or oversized replacement, so neither is used.
  readonly property string readState: Qt.resolvedUrl("bin/read-state.py").toString().replace(/^file:\/\//, "")
  readonly property string writeState: Qt.resolvedUrl("bin/write-state.py").toString().replace(/^file:\/\//, "")

  Process {
    id: reader
    command: ["python3", root.readState, root.statePath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyState(text)
    }
  }

  // Cheap change detection: re-read at most every 1.5 s. Bounded reads exit
  // immediately whatever sits at the path, so this cannot hang or balloon.
  Timer {
    interval: 1500
    running: true
    repeat: true
    onTriggered: if (!reader.running) reader.running = true
  }

  function applyState(text) {
    var parsed
    try { parsed = JSON.parse(text) } catch (e) { return }
    if (!parsed || typeof parsed !== "object") return

    var st = {
      autoMute: parsed.autoMute !== false,
      workspaces: parsed.workspaces || {}
    }
    root.state = st

    // Drop intents the file has confirmed.
    var d = {}
    for (var k in root.desired) {
      var want = root.desired[k]
      if (k === "_auto") {
        if (want !== st.autoMute) d[k] = want
        continue
      }
      var have = st.workspaces[k] || {}
      var keep = false
      if (want.muted !== undefined && want.muted !== (have.muted === true)) keep = true
      if (want.volume !== undefined && want.volume !== (have.volume !== undefined && have.volume !== null ? have.volume : null)) keep = true
      if (keep) d[k] = want
    }
    root.desired = d
  }

  // ---------- writing ----------
  // Payload is base64-encoded so no workspace name or value can carry shell
  // or argument semantics, then handed to the shared helper which writes the
  // exclusive temp inode in one open and atomically renames it into place.
  Process { id: writer }

  function writeFile(payload) {
    var json = JSON.stringify(payload).replace(/[\u0080-\uFFFF]/g, function(ch) {
      var h = ch.charCodeAt(0).toString(16)
      while (h.length < 4) h = "0" + h
      return "\\u" + h
    })
    writer.command = ["bash", "-c",
      "mkdir -p -m 700 '" + root.runtimeDir + "' && exec python3 '" + root.writeState +
      "' \"$1\" '" + root.statePath + "'", "sh", Qt.btoa(json)]
    writer.running = true
  }

  // Merge the desired overlay over known file state and persist everything.
  function flush() {
    var w = {}
    for (var k in root.desired) {
      if (k === "_auto") continue
      var src = root.state.workspaces[k] || {}
      var des = root.desired[k]
      var ent = {}
      ent.muted = des.muted !== undefined ? des.muted : (src.muted === true)
      var vol = des.volume !== undefined ? des.volume
              : (src.volume !== undefined && src.volume !== null ? src.volume : null)
      if (vol !== null) ent.volume = vol
      w[k] = ent
    }
    writeFile({
      autoMute: root.desired._auto !== undefined ? root.desired._auto : root.state.autoMute,
      workspaces: w
    })
  }

  function setWsMuted(id, muted) {
    var k = String(id)
    var d = Object.assign({}, root.desired)
    var e = Object.assign({}, d[k] || {})
    e.muted = muted
    d[k] = e
    root.desired = d
    flush()
  }

  function setWsVolume(id, percent) {
    var k = String(id)
    var d = Object.assign({}, root.desired)
    var e = Object.assign({}, d[k] || {})
    e.volume = percent
    d[k] = e
    root.desired = d
    flush()
  }

  function resetWs(id) {
    var k = String(id)
    var d = Object.assign({}, root.desired)
    delete d[k]
    root.desired = d
    // Rewrite the file without this workspace; other desired entries persist.
    var w = {}
    for (var k2 in root.desired) {
      if (k2 === "_auto" || k2 === k) continue
      var src = root.state.workspaces[k2] || {}
      var des = root.desired[k2]
      var ent = {}
      ent.muted = des.muted !== undefined ? des.muted : (src.muted === true)
      var vol = des.volume !== undefined ? des.volume
              : (src.volume !== undefined && src.volume !== null ? src.volume : null)
      if (vol !== null) ent.volume = vol
      w[k2] = ent
    }
    writeFile({
      autoMute: root.desired._auto !== undefined ? root.desired._auto : root.state.autoMute,
      workspaces: w
    })
  }

  function toggleAutoMute() {
    var cur = root.desired._auto !== undefined ? root.desired._auto : root.state.autoMute
    var d = Object.assign({}, root.desired)
    d._auto = !cur
    root.desired = d
    flush()
  }

  // Effective values for rendering (intent wins until the file confirms).
  function effMuted(id) {
    var k = String(id)
    var d = root.desired[k]
    if (d && d.muted !== undefined) return d.muted
    var f = root.state.workspaces[k]
    return f ? f.muted === true : false
  }

  function effVolume(id) {
    var k = String(id)
    var d = root.desired[k]
    if (d && d.volume !== undefined) return d.volume / 100.0
    var f = root.state.workspaces[k]
    return f && f.volume !== undefined && f.volume !== null ? f.volume / 100.0 : 1.0
  }

  function effCustom(id) {
    var k = String(id)
    var d = root.desired[k]
    if (d && d.volume !== undefined) return true
    var f = root.state.workspaces[k]
    return !!(f && f.volume !== undefined && f.volume !== null)
  }

  function effAutoMute() {
    return root.desired._auto !== undefined ? root.desired._auto : root.state.autoMute
  }

  // ---------- workspace discovery ----------
  Process {
    id: wsProc
    command: ["bash", "-c",
      "echo -n '{\"workspaces\":' ;" +
      "hyprctl workspaces -j | jq -c 'sort_by(.id) | map({id: .id, name: (.name // \"\")})' ;" +
      "echo -n ',\"focused\":' ;" +
      "hyprctl monitors -j | jq -c '[.[].activeWorkspace.id] | unique' ;" +
      "echo -n '}'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          root.workspaces = data.workspaces || []
          root.focusedIds = data.focused || []
        } catch (e) {}
      }
    }
  }

  function refresh() {
    if (!wsProc.running) wsProc.running = true
    if (!reader.running) reader.running = true
  }

  Timer {
    interval: 2000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onOpenedChanged: if (opened) Qt.callLater(root.refresh)

  function isFocused(id) { return root.focusedIds.indexOf(id) >= 0 }

  // ---------- bar button + panel ----------
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰕾"
    tooltipText: "Silence - workspace audio"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(330))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(500))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(10)

          // ---- header: title + auto-mute switch ----
          Item {
            width: panelColumn.width
            height: Math.max(headerText.implicitHeight, autoSwitch.implicitHeight)

            Text {
              id: headerText
              text: "WORKSPACE AUDIO"
              color: root.fg
              font.family: root.ff
              font.pixelSize: Style.font.title
              font.bold: true
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            ToggleSwitch {
              id: autoSwitch
              checked: root.effAutoMute()
              foreground: root.fg
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.toggleAutoMute()
            }
          }

          Text {
            width: panelColumn.width
            height: implicitHeight
            text: effAutoMute() ? "Background workspaces muted"
                                : "All workspaces audible"
            color: Qt.darker(root.fg, 1.4)
            font.family: root.ff
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.1
            elide: Text.ElideRight
          }

          PanelSeparator { foreground: root.fg; width: panelColumn.width; height: Style.space(4) }

          Item {
            visible: root.workspaces.length === 0
            width: panelColumn.width
            height: emptyText.implicitHeight

            Text {
              id: emptyText
              text: "No workspaces found"
              color: Qt.darker(root.fg, 1.4)
              font.family: root.ff
              font.pixelSize: Style.font.body
            }
          }

          // ---- one row per workspace ----
          Repeater {
            model: root.workspaces

            delegate: Column {
              id: row
              required property var modelData

              width: panelColumn.width
              spacing: Style.space(3)

              // -- top line: label · reset · mute --
              Item {
                width: row.width
                height: Math.max(wsLabel.implicitHeight, muteSwitch.implicitHeight)

                Text {
                  id: wsLabel
                  text: (row.modelData.name !== "" ? row.modelData.name : String(row.modelData.id))
                        + (root.isFocused(row.modelData.id) ? "  •" : "")
                  color: root.fg
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  font.bold: root.isFocused(row.modelData.id)
                  elide: Text.ElideRight
                  width: parent.width - muteSwitch.width - resetButton.width - Style.space(24)
                  opacity: root.effMuted(row.modelData.id) ? 0.5 : 1.0
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: resetButton
                  text: "↺"
                  color: Qt.darker(root.fg, 1.4)
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  opacity: root.effCustom(row.modelData.id) ? 1.0 : 0.25
                  anchors.right: muteSwitch.left
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter

                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.space(6)
                    cursorShape: Qt.PointingHandCursor
                    enabled: root.effCustom(row.modelData.id)
                    onClicked: root.resetWs(row.modelData.id)
                  }
                }

                ToggleSwitch {
                  id: muteSwitch
                  checked: root.effMuted(row.modelData.id)
                  foreground: root.fg
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  onToggled: root.setWsMuted(row.modelData.id, !root.effMuted(row.modelData.id))
                }
              }

              // -- bottom line: volume slider --
              PanelSlider {
                id: slider
                bar: root.bar
                width: parent.width
                minimum: 0
                maximum: 1
                step: 0.05
                value: root.effVolume(row.modelData.id)
                opacity: root.effMuted(row.modelData.id) ? 0.35 : (root.effCustom(row.modelData.id) ? 1.0 : 0.65)

                Timer {
                  id: commitTimer
                  interval: 150
                  onTriggered: root.setWsVolume(row.modelData.id, slider._pending)
                }

                property real _pending: -1

                onMoved: function(v) {
                  _pending = Math.round(v * 100)
                  commitTimer.restart()
                }
                onReleased: function(v) {
                  commitTimer.stop()
                  root.setWsVolume(row.modelData.id, Math.round(v * 100))
                }
              }
            }
          }
        }
      }
    }
  }
}
