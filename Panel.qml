import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import qs.Commons as Commons

// UPS Status: an apcupsd UPS on the bar. Shows the battery charge (and minutes left
// when on battery); the panel has the details and the machines the UPS powers.
//
// Data comes from bin/ups-status, which runs `apcaccess status <server>` and pings
// each listed machine once. Settings live in this widget's shell.json entry:
//   "server":   apcupsd host:port (default 127.0.0.1:3551, your own apcupsd)
//   "machines": [{ "name": "nas", "host": "192.168.1.20" }, ...] (optional)
//   "interval": seconds between checks (default 15)
//   "notify":   desktop notification when power is lost or restored (default true)
Panel {
  id: root
  moduleName: "jim.ups-status"
  ipcTarget: "jim.ups-status"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string helper: Qt.resolvedUrl("bin/ups-status").toString().replace(/^file:\/\//, "")
  readonly property string server: String(setting("server", "127.0.0.1:3551"))
  readonly property var machines: normaliseMachines(setting("machines", []))
  readonly property int interval: Math.max(5, Number(setting("interval", 15)))
  readonly property bool notify: setting("notify", true) !== false
  readonly property color dim: Qt.darker(Commons.Color.popups.text, 1.6)

  property var ups: null          // last bin/ups-status result
  property string lastState: ""   // "online" | "onbatt" | "unreachable", for notifications
  property int misses: 0          // failed checks in a row
  // A busy apcupsd (its network server answers one client at a time) or a network blip can drop checks;
  // only call the UPS unreachable after this many failures in a row (about 2 min at the default interval).
  readonly property int missLimit: 8
  property double nowMs: Date.now()

  readonly property bool hasData: !!(ups && ups.ok)
  readonly property string state: !ups ? "" : !ups.ok ? "unreachable" : ups.onBattery ? "onbatt" : "online"
  readonly property bool alarm: state === "onbatt" || state === "unreachable"

  // Accepts [{name, host}], ["name=host"] or ["host"].
  function normaliseMachines(list) {
    var out = []
    // shell.json arrays can arrive as QML lists rather than JS arrays, so go by length.
    if (!list || typeof list === "string" || !(list.length > 0)) return out
    for (var i = 0; i < list.length; i++) {
      var m = list[i]
      if (typeof m === "string") {
        var parts = m.split("=")
        out.push(parts.length > 1 ? parts[0] + "=" + parts.slice(1).join("=") : m + "=" + m)
      } else if (m && m.host) {
        out.push(String(m.name || m.host) + "=" + String(m.host))
      }
    }
    return out
  }

  function round(n) { return Math.round(Number(n || 0)) }

  function icon() {
    if (state === "unreachable") return "󰚦"
    if (state === "onbatt") return "󰂃"
    if (hasData && ups.charging) return "󰂄"
    return "󰚥"
  }

  function barText() {
    if (!ups) return "󰚥"
    if (state === "unreachable") return icon() + " UPS?"
    if (state === "onbatt") return icon() + " " + round(ups.charge) + "% " + round(ups.timeLeft) + "m"
    return icon() + " " + round(ups.charge) + "%"
  }

  function summary() {
    if (!ups) return "Checking the UPS…"
    if (state === "unreachable") return "UPS not answering (" + (ups.error || server) + ")"
    if (state === "onbatt") return "On battery: " + round(ups.charge) + "%, about " + round(ups.timeLeft) + " min left"
    return "On mains power" + (ups.lineVoltage ? " (" + round(ups.lineVoltage) + " V)" : "") + ", battery " + round(ups.charge) + "%"
  }

  function tooltip() {
    if (!hasData) return summary()
    var up = 0
    for (var i = 0; i < ups.machines.length; i++) if (ups.machines[i].up) up++
    return summary() + (ups.machines.length ? "\n" + up + " of " + ups.machines.length + " machines answering" : "")
  }

  function formatAge(ms) {
    if (!(ms > 0) || ms < 60000) return "just now"
    var minutes = Math.floor(ms / 60000)
    if (minutes < 60) return minutes + " min ago"
    return Math.floor(minutes / 60) + " h ago"
  }

  function refresh() {
    if (proc.running) return
    proc.command = [helper, server].concat(machines)
    proc.running = true
  }

  // Notify once per state change (not on the first reading).
  function handleState() {
    if (!state || state === lastState) return
    if (lastState !== "" && notify) {
      // Only a real power loss stays on screen until dismissed; "not answering" is usually the network, not the UPS.
      var urgency = state === "onbatt" ? "critical" : "normal"
      var title = state === "online" ? (lastState === "unreachable" ? "UPS: answering again" : "UPS: power restored") : state === "onbatt" ? "UPS: ON BATTERY" : "UPS: not answering"
      Util.execArgv(["notify-send", "-a", "UPS", "-u", urgency, title, summary()])
    }
    lastState = state
  }

  onOpenedChanged: if (opened) { nowMs = Date.now(); refresh() }
  onServerChanged: refresh()
  onMachinesChanged: refresh()

  Process {
    id: proc
    stdout: StdioCollector {
      onStreamFinished: {
        var data = null
        try { data = JSON.parse(text) } catch (e) {}
        if (!data) data = { ok: false, error: "ups-status printed nothing", machines: [] }
        root.nowMs = Date.now()
        if (data.ok) root.misses = 0
        else if (++root.misses < root.missLimit) return  // keep the last reading ("Updated … ago" shows its age)
        root.ups = data
        root.handleState()
      }
    }
  }

  Timer {
    interval: root.interval * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---------------------------------------------------------------- bar button
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText()
    active: root.opened || root.alarm
    tooltipText: root.opened ? "" : root.tooltip()
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) { root.refresh(); root.open() }
      else root.toggle()
    }
  }

  // ---------------------------------------------------------------- panel
  component Label: Text {
    color: Commons.Color.popups.text
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  component Stat: RowLayout {
    property string name: ""
    property string value: ""
    Layout.fillWidth: true
    visible: value !== ""
    spacing: Style.spacing.lg
    Label { text: parent.name; color: root.dim; elide: Text.ElideNone }
    Label { Layout.fillWidth: true; text: parent.value; horizontalAlignment: Text.AlignRight }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: root.refresh()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refresh() }

      Flickable {
        anchors.fill: parent
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
          id: column
          width: parent.width
          spacing: Style.spacing.xl

          // Headline
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.xxs
            Label {
              Layout.fillWidth: true
              text: root.hasData ? (root.ups.model || root.ups.upsName || "UPS") : "UPS"
              font.bold: true
            }
            Label {
              Layout.fillWidth: true
              wrapMode: Text.Wrap
              elide: Text.ElideNone
              text: root.summary()
              color: root.alarm ? Commons.Color.urgent : Commons.Color.popups.text
            }
          }

          // Charge bar
          Rectangle {
            Layout.fillWidth: true
            visible: root.hasData
            implicitHeight: Style.space(10)
            radius: Style.space(5)
            color: Util.alpha(Commons.Color.popups.text, 0.12)
            Rectangle {
              width: parent.width * Math.max(0, Math.min(100, root.hasData ? root.ups.charge : 0)) / 100
              height: parent.height
              radius: parent.radius
              color: root.alarm ? Commons.Color.urgent : Commons.Color.accent
            }
          }

          // Details
          ColumnLayout {
            Layout.fillWidth: true
            visible: root.hasData
            spacing: Style.spacing.sm
            Stat { name: "Runtime"; value: root.hasData && root.ups.timeLeft !== undefined ? root.round(root.ups.timeLeft) + " min" : "" }
            Stat {
              name: "Load"
              value: root.hasData && root.ups.load !== undefined
                ? root.round(root.ups.load) + "%" + (root.ups.watts !== undefined ? " (~" + root.ups.watts + " W)" : "") : ""
            }
            Stat { name: "Status"; value: root.hasData ? String(root.ups.status || "") : "" }
            Stat { name: "Battery date"; value: root.hasData ? String(root.ups.batteryDate || "") : "" }
            Stat { name: "Transfers"; value: root.hasData && root.ups.transfers !== undefined ? String(root.round(root.ups.transfers)) : "" }
            Stat { name: "Last transfer"; value: root.hasData ? String(root.ups.lastTransfer || "") : "" }
            Stat { name: "Server"; value: root.hasData ? (root.ups.hostname ? root.ups.hostname + " · " : "") + root.ups.server : "" }
          }

          // Machines
          ColumnLayout {
            Layout.fillWidth: true
            visible: !!(root.ups && root.ups.machines && root.ups.machines.length)
            spacing: Style.spacing.sm
            PanelSeparator { Layout.fillWidth: true }
            Label { text: "Machines on this UPS"; font.bold: true }
            Repeater {
              model: root.ups && root.ups.machines ? root.ups.machines : []
              delegate: RowLayout {
                id: row
                required property var modelData
                Layout.fillWidth: true
                spacing: Style.spacing.lg
                Label { text: row.modelData.up ? "●" : "○"; color: row.modelData.up ? Commons.Color.accent : Commons.Color.urgent }
                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 0
                  Label {
                    Layout.fillWidth: true
                    text: row.modelData.name + (row.modelData.isSelf ? " (this machine)" : "")
                    font.bold: !!row.modelData.isSelf
                  }
                  Label {
                    Layout.fillWidth: true
                    color: root.dim
                    font.pixelSize: Style.font.bodySmall
                    text: row.modelData.host
                      + (row.modelData.isServer ? " · apcupsd server" : "")
                      + (row.modelData.client ? " · client: " + row.modelData.client : "")
                      + (row.modelData.up ? "" : " · not answering")
                  }
                }
              }
            }
          }

          // Footer
          RowLayout {
            Layout.fillWidth: true
            Label {
              Layout.fillWidth: true
              color: root.dim
              font.pixelSize: Style.font.bodySmall
              text: proc.running ? "Checking…" : root.ups ? "Updated " + root.formatAge(root.nowMs - root.ups.updatedAt * 1000) : ""
            }
            Button {
              text: "Refresh"
              foreground: Commons.Color.popups.text
              bordered: true
              enabled: !proc.running
              tooltipText: "Check now (R)"
              onClicked: root.refresh()
            }
          }
        }
      }
    }
  }
}
