// Bar button + popout. Presentation only: every value comes from SeerrService.qml.
// Structure and property names follow ky.jellyfin-nowplaying, which is the working
// reference for Omarchy's bar-widget contract on this machine.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "ky.seerr-requests"
  ipcTarget: "ky.seerr-requests"
  manageIpc: false

  // ⛔ WITHOUT THESE THE WIDGET IS INVISIBLE. A Panel with no implicit size gets
  // allocated zero width by the bar: it loads, runs, logs nothing fatal, and simply
  // never appears. Empty queue -> zero width, which is how "quiet when there is
  // nothing to approve" is honestly expressed; a FAULT keeps its width, so broken
  // never looks like an empty queue.
  implicitWidth: (seerr.ok && seerr.pending === 0 && root.hideWhenEmpty) ? 0 : button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  // The `bar` object handed to a widget exposes foreground/urgent/fontFamily but not
  // background or accent -- reading those off it yields undefined, which QML assigns
  // as black and only reports as a runtime warning. Both come from the theme
  // singleton instead, which is also what recolours them on a theme change.
  readonly property color background: Color.bar.background
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool hideWhenEmpty: (root.settings && root.settings.hideWhenEmpty !== undefined)
                                        ? root.settings.hideWhenEmpty : true

  // "2026-08-09T13:38:48.000Z" -> "2d ago". Anything older than a week is a date,
  // because "23d ago" stops meaning anything and starts being a number to decode.
  function fmtAge(iso) {
    if (!iso) return ""
    var t = Date.parse(iso)
    if (isNaN(t)) return ""
    var s = Math.max(0, (Date.now() - t) / 1000)
    if (s < 90) return "just now"
    if (s < 3600) return Math.round(s / 60) + "m ago"
    if (s < 86400) return Math.round(s / 3600) + "h ago"
    if (s < 604800) return Math.round(s / 86400) + "d ago"
    return new Date(t).toLocaleDateString(Qt.locale(), Locale.ShortFormat)
  }

  SeerrService {
    id: seerr
    refreshIntervalSec: (root.settings && root.settings.refreshIntervalSec) ? root.settings.refreshIntervalSec : 60
    notifyOnNew: (root.settings && root.settings.notifyOnNew !== undefined) ? root.settings.notifyOnNew : true
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // BarIconButton renders `iconComponent` through a Loader and hides the glyph Text
    // when it is non-null (BarIconButton.qml:32), so `text` must stay empty or both
    // would count as content. The bar gives each widget ONE fixed square slot
    // (fixedWidth: slotSize), which is why the count rides the logo as a badge rather
    // than sitting beside it -- there is no room beside it to sit in.
    text: ""
    iconComponent: Component {
      Item {
        anchors.fill: parent

        Image {
          anchors.fill: parent
          source: Qt.resolvedUrl("seerr.svg")
          // Rasterise at 2x the slot and downscale: letting Image scale the SVG at its
          // intrinsic size leaves it soft on a HiDPI bar.
          sourceSize.width: 64
          sourceSize.height: 64
          fillMode: Image.PreserveAspectFit
          smooth: true
          opacity: seerr.ok ? 1.0 : 0.55
        }

        // The count, or "!" when the poll is failing. A fault takes the urgent colour
        // AND its own glyph, because a dead API key must never be able to render as a
        // quiet queue -- the one failure here that otherwise hides itself perfectly.
        Rectangle {
          id: badge
          visible: !seerr.ok || seerr.pending > 0
          anchors.right: parent.right
          anchors.top: parent.top
          height: Math.round(parent.height * 0.46)
          width: Math.max(height, badgeText.implicitWidth + Style.space(4))
          radius: height / 2
          color: seerr.ok ? root.accent : root.urgent
          // Ring it in the bar's own background so the badge reads as sitting on top
          // of the logo rather than melting into the artwork underneath.
          border.width: 1
          border.color: root.background

          Text {
            id: badgeText
            anchors.centerIn: parent
            // Past 99 the exact number stops being information and becomes a wall of
            // digits in a 20px slot.
            text: seerr.ok ? (seerr.pending > 99 ? "99+" : String(seerr.pending)) : "!"
            color: root.background
            font.family: root.fontFamily
            font.pixelSize: Math.round(badge.height * 0.7)
            font.bold: true
          }
        }
      }
    }
    dimmed: seerr.ok && seerr.pending === 0
    tooltipText: "Seerr: " + seerr.barSummary + (seerr.stale ? " (showing last known)" : "")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) seerr.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTextKey: function(t) { if (t === "r" || t === "R") seerr.refresh() }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true

        ColumnLayout {
          id: column
          width: parent.width
          spacing: Style.space(10)

          Text {
            Layout.fillWidth: true
            text: "Seerr requests"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          // Fault state, worded. "unreachable" and "auth failed" are different
          // problems with different fixes, so they are never collapsed into one.
          Text {
            Layout.fillWidth: true
            visible: !seerr.ok
            text: "Not available — " + seerr.error + (seerr.stale ? " (showing last known)" : "")
            color: root.urgent
            font.family: root.fontFamily
            wrapMode: Text.WordWrap
          }

          Text {
            Layout.fillWidth: true
            visible: !seerr.ok && seerr.error === "not configured"
            text: "Create ~/.config/omarchy-seerr/config.json with url, api_key and web_base."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            Layout.fillWidth: true
            visible: seerr.ok && seerr.pending === 0
            text: "Nothing waiting for approval."
            color: root.dim
            font.family: root.fontFamily
          }

          // The last action's failure, kept visible until the next action succeeds.
          Text {
            Layout.fillWidth: true
            visible: seerr.actionError !== ""
            text: "Action failed — " + seerr.actionError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: seerr.requests
            delegate: RowLayout {
              required property var modelData
              Layout.fillWidth: true
              spacing: Style.space(8)

              readonly property bool busy: seerr.busyId === modelData.id
              readonly property bool failed: seerr.failedId === modelData.id

              Image {
                Layout.alignment: Qt.AlignTop
                visible: !!modelData.poster
                source: modelData.poster || ""
                sourceSize.width: Style.space(92)   // 2x the slot: TMDB w185 downscaled stays crisp on HiDPI
                Layout.preferredWidth: Style.space(46)
                Layout.preferredHeight: Style.space(69)   // posters are 2:3
                fillMode: Image.PreserveAspectFit
                smooth: true
                asynchronous: true                  // never let a slow CDN stall the panel
                opacity: parent.busy ? 0.4 : 1.0
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(2)

                // Click the title to open the request in Seerr. The URL is built by
                // the backend, so QML never needs to know the server address.
                Text {
                  Layout.fillWidth: true
                  text: modelData.title + (modelData.year ? " (" + modelData.year + ")" : "")
                  color: titleMouse.containsMouse ? root.urgent : root.foreground
                  font.family: root.fontFamily
                  font.bold: true
                  font.underline: titleMouse.containsMouse
                  wrapMode: Text.WordWrap

                  MouseArea {
                    id: titleMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      Qt.openUrlExternally(modelData.web_url)
                      root.close()   // opening a browser over the panel leaves it stranded
                    }
                  }
                }

                Text {
                  Layout.fillWidth: true
                  text: modelData.requested_by + " · " + root.fmtAge(modelData.created_at)
                        + (modelData.seasons ? " · " + modelData.seasons : "")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Text {
                  Layout.fillWidth: true
                  visible: parent.parent.busy || parent.parent.failed
                  text: parent.parent.busy ? "working…" : "did not go through"
                  color: parent.parent.failed ? root.urgent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              PanelActionButton {
                Layout.alignment: Qt.AlignVCenter
                iconText: ""
                tooltipText: "Approve"
                foreground: root.dim
                hoverColor: root.accent
                enabled: seerr.busyId === 0
                onClicked: seerr.approve(modelData.id)
              }

              PanelActionButton {
                Layout.alignment: Qt.AlignVCenter
                iconText: ""
                tooltipText: "Decline"
                foreground: root.dim
                hoverColor: root.urgent
                enabled: seerr.busyId === 0
                onClicked: seerr.decline(modelData.id)
              }
            }
          }

          // The count is always exact even when the list is capped; saying so beats
          // a list that quietly stops being the whole queue.
          Text {
            Layout.fillWidth: true
            visible: seerr.truncated
            text: "Showing " + seerr.count + " of " + seerr.pending + " — open Seerr for the rest."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
