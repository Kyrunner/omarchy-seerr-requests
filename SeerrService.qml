// Owns the poll, the parsed state, and the approve/decline calls.
// Knows nothing about how any of it is drawn.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: svc

  property int refreshIntervalSec: 60
  property bool notifyOnNew: true
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

  // ---- state the panel reads ----
  property bool ok: false
  property string error: "starting"
  property int pending: 0
  property var requests: []
  property bool truncated: false
  property bool stale: false          // last poll failed but we still have old data

  // Which row is mid-action, and what went wrong if it did. Only one action can be
  // in flight: they are user-initiated one at a time, and serialising them keeps a
  // double-click from approving and declining the same request in either order.
  property int busyId: 0
  property int failedId: 0
  property string actionError: ""

  readonly property int count: requests ? requests.length : 0
  readonly property string barSummary: {
    if (!ok) return error
    if (pending === 0) return "nothing waiting"
    return pending === 1 ? "1 request needs approval" : pending + " requests need approval"
  }

  Process {
    id: poll
    command: ["bash", svc.pluginDir + "/backend.sh", svc.notifyOnNew ? "--notify" : "poll"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var raw = this.text ? this.text.trim() : ""
        if (raw === "") { svc.stale = svc.count > 0; svc.ok = false; svc.error = "no output"; return }
        try {
          var d = JSON.parse(raw)
          svc.ok = !!d.ok
          svc.error = d.error ? String(d.error) : ""
          if (d.ok) {
            svc.pending = d.pending || 0
            svc.requests = d.requests || []
            svc.truncated = !!d.truncated
            svc.stale = false
          } else {
            svc.stale = svc.count > 0   // keep last-known, mark it stale
          }
        } catch (e) {
          svc.ok = false; svc.error = "unparseable"; svc.stale = svc.count > 0
        }
      }
    }
  }

  Process {
    id: action
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var raw = this.text ? this.text.trim() : ""
        var okAction = false
        try { okAction = !!JSON.parse(raw).ok } catch (e) { okAction = false }

        if (okAction) {
          svc.failedId = 0
          svc.actionError = ""
        } else {
          // Surface it on the row and leave the row in place. A silent failure that
          // looks like success leaves the requester waiting on a queue you believe
          // you cleared -- the one outcome worth being slow to avoid.
          svc.failedId = svc.busyId
          var msg = "failed"
          try { msg = JSON.parse(raw).error || "failed" } catch (e) {}
          svc.actionError = String(msg)
        }
        svc.busyId = 0
        svc.refresh()   // the server is the authority on what is still pending
      }
    }
  }

  function refresh() { if (!poll.running) poll.running = true }

  function act(verb, id) {
    if (action.running || busyId !== 0) return
    busyId = id
    failedId = 0
    actionError = ""
    action.command = ["bash", pluginDir + "/backend.sh", verb, String(id)]
    action.running = true
  }

  function approve(id) { act("approve", id) }
  function decline(id) { act("decline", id) }

  Timer {
    interval: Math.max(15, svc.refreshIntervalSec) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: svc.refresh()
  }
}
