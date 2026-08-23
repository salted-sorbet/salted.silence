import QtQuick
import Quickshell
import Quickshell.Io

// Spawns the bundled audio daemon on shell startup. The daemon self-guards
// with flock, so a respawn (shell restart, plugin reload) never doubles up.
Item {
  id: root

  property var shell: null
  property string omarchyPath: ""
  property var manifest: null

  readonly property string daemonPath: Qt.resolvedUrl("bin/silenced.sh").toString().replace(/^file:\/\//, "")

  Process {
    running: true
    command: ["bash", "-c", "exec '" + root.daemonPath + "'"]
  }
}
