pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "anavarre.apple-podcasts"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  // The plugin's Service.qml singleton, handed down by the bar widget. Until it
  // appears the panel reads an inert stand-in so every binding has something
  // to read.
  property var service: null
  readonly property var podcasts: root.service || inertService

  readonly property bool authenticated: root.podcasts.authenticated === true
  readonly property string authState: root.podcasts.authState
  readonly property bool loading: root.podcasts.loading === true
  readonly property bool saving: root.podcasts.saving === true
  readonly property string errorText: root.podcasts.errorText
  readonly property string signInError: root.podcasts.signInError
  readonly property var episodes: root.podcasts.episodes
  readonly property bool signedIn: root.authenticated || root.authState === "offline"

  // Player state, read off the service.
  readonly property var nowPlaying: root.podcasts.nowPlaying
  readonly property string playerState: root.podcasts.playerState
  readonly property real position: root.podcasts.position
  readonly property real duration: root.podcasts.duration
  readonly property string playError: root.podcasts.playError
  readonly property int skipBack: root.podcasts.skipBackSeconds
  readonly property int skipForward: root.podcasts.skipForwardSeconds
  readonly property real speed: root.podcasts.speed
  readonly property var speedChoices: Model.speedChoices
  property bool speedOpen: false
  readonly property bool isPlaying: root.playerState === "playing"
  // The focused player replaces the list while it is up; Escape goes back.
  property bool playerOpen: false
  readonly property bool showPlayer: root.playerOpen && root.nowPlaying !== null
    && root.signedIn && !root.showAccount

  // The account view is reached from the footer; signing in shows by itself
  // when nothing works yet.
  property bool accountOpen: false
  readonly property bool showSignIn: !root.signedIn && root.authState !== "unknown"
  readonly property bool showAccount: root.accountOpen && root.signedIn
  property int selected: 0

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Color.muted
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property real cardWidth: panel.fittedContentWidth(Style.space(460))

  QtObject {
    id: inertService
    readonly property bool authenticated: false
    readonly property string authState: "unknown"
    readonly property bool loading: false
    readonly property bool saving: false
    readonly property string errorText: ""
    readonly property string signInError: ""
    readonly property var episodes: []
    readonly property var positions: ({})
    readonly property var nowPlaying: null
    readonly property string playerState: "idle"
    readonly property real position: 0
    readonly property real duration: 0
    readonly property string playError: ""
    readonly property int skipBackSeconds: 15
    readonly property int skipForwardSeconds: 15
    property bool playerVisible: false
    readonly property real speed: 1
    function setSpeed(rate) {}
    function play(episode) {}
    function togglePlay() {}
    function skip(seconds) {}
    function seekTo(seconds) {}
    function stopPlayback() {}
    function refresh() {}
    function signIn(token) {}
    function forget() {}
    function openUrl(url) {}
  }

  onOpenedChanged: {
    if (root.opened) {
      root.accountOpen = false
      root.playerOpen = false
      root.speedOpen = false
      root.selected = 0
      if (root.signedIn) root.podcasts.refresh()
    }
  }

  // Tell the service when the player is on screen, so it polls mpv every
  // second only then.
  readonly property bool playerOnScreen: root.opened && root.nowPlaying !== null && root.signedIn && !root.showAccount
  onPlayerOnScreenChanged: { if (root.service) root.service.playerVisible = root.playerOnScreen }

  function moveSelection(dy) {
    if (root.episodes.length === 0) return
    root.selected = Math.max(0, Math.min(root.episodes.length - 1, root.selected + dy))
  }

  function openEpisode(index) {
    var e = root.episodes[index]
    if (!e) return
    root.podcasts.play(e)
    root.playerOpen = true
  }

  function seekFromClick(x, width) {
    if (root.duration > 0 && width > 0) root.podcasts.seekTo(root.duration * Math.max(0, Math.min(1, x / width)))
  }

  function submitToken() {
    if (tokenField.text.trim() === "" || root.saving) return
    root.podcasts.signIn(tokenField.text)
    tokenField.text = ""
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: root.showSignIn ? tokenField : keys
    contentWidth: root.cardWidth
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      // The sign-in form owns the keyboard while it is up, so typing a token
      // doesn't drive the list underneath it.
      blocked: root.showSignIn
      onMoveRequested: function(dx, dy) {
        if (root.showPlayer) {
          if (dx < 0) root.podcasts.skip(-root.skipBack)
          else if (dx > 0) root.podcasts.skip(root.skipForward)
        }
        else if (!root.showAccount && dy !== 0) root.moveSelection(dy)
      }
      onActivateRequested: {
        if (root.showAccount) { root.podcasts.forget(); root.accountOpen = false }
        else if (root.showPlayer) root.podcasts.togglePlay()
        else root.openEpisode(root.selected)
      }
      onCloseRequested: {
        if (root.showAccount) root.accountOpen = false
        else if (root.showPlayer && root.speedOpen) root.speedOpen = false
        else if (root.showPlayer) root.playerOpen = false
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (root.showPlayer) {
          if (text === "o" && root.nowPlaying && root.nowPlaying.url !== "") root.podcasts.openUrl(root.nowPlaying.url)
          else if (text === "s") { root.podcasts.stopPlayback(); root.playerOpen = false }
          return
        }
        if (text === "r") root.podcasts.refresh()
        else if (text === "c") root.accountOpen = !root.accountOpen
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        // ------------------------------------------------------ sign-in form
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.showSignIn

          Text {
            width: parent.width
            text: "Sign in to Apple Podcasts"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: "Apple has no sign-in for third-party apps, so this uses your session on the web player. "
              + "1. Press Open and sign in with your Apple Account. "
              + "2. In the browser's developer tools, open Storage/Application → Cookies → podcasts.apple.com "
              + "and copy the value of media-user-token. 3. Paste it here."
          }

          Text {
            width: parent.width
            visible: root.signInError !== ""
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: root.signInError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: tokenField
            width: parent.width
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            password: true
            placeholderText: "media-user-token"
            onAccepted: root.submitToken()
            Keys.onEscapePressed: root.close()
          }

          Row {
            spacing: Style.space(8)
            Button {
              text: "Open podcasts.apple.com"
              onClicked: root.podcasts.openUrl("https://podcasts.apple.com/us/library")
            }
            Button {
              text: root.saving ? "Checking…" : "Sign in"
              enabled: !root.saving
              onClicked: root.submitToken()
            }
          }
        }

        // ------------------------------------------------------------ account
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.showAccount

          Text {
            width: parent.width
            text: "Signed in"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: "Enter forgets the stored token. It does not sign you out of Apple; do that on the web player."
          }
        }

        // -------------------------------------------------------------- player
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.showPlayer

          Text {
            text: "← Episodes  (Esc)"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.playerOpen = false }
          }

          Image {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Style.space(160)
            height: width
            visible: source !== ""
            source: root.nowPlaying ? root.nowPlaying.artworkLarge : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: root.nowPlaying ? root.nowPlaying.title : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            textFormat: Text.PlainText
            visible: text !== ""
            text: root.nowPlaying ? root.nowPlaying.show : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          // Progress: click anywhere on the bar to jump there.
          Item {
            id: progress
            width: parent.width
            height: Style.space(18)

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width
              height: Style.space(4)
              radius: height / 2
              color: Qt.alpha(root.foreground, 0.2)
              Rectangle {
                width: root.duration > 0 ? parent.width * Math.min(1, root.position / root.duration) : 0
                height: parent.height
                radius: parent.radius
                color: root.accent
              }
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: function(mouse) { root.seekFromClick(mouse.x, progress.width) }
            }
          }

          Item {
            width: parent.width
            height: clockLeft.implicitHeight
            Text {
              id: clockLeft
              text: Model.formatClock(root.position)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              anchors.right: parent.right
              text: root.duration > 0 ? "-" + Model.formatClock(root.duration - root.position) : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(10)
            Button {
              text: Model.formatSpeed(root.speed)
              tooltipText: "Playback speed"
              active: root.speedOpen
              onClicked: root.speedOpen = !root.speedOpen
            }
            Button {
              text: "−" + root.skipBack + "s"
              tooltipText: "Back " + root.skipBack + " seconds (←)"
              enabled: root.playerState !== "ended"
              onClicked: root.podcasts.skip(-root.skipBack)
            }
            Button {
              text: root.playerState === "ended" ? "Replay" : root.isPlaying ? "Pause" : root.playerState === "buffering" ? "Loading…" : "Play"
              tooltipText: "Play / pause (Space)"
              onClicked: root.podcasts.togglePlay()
            }
            Button {
              text: "+" + root.skipForward + "s"
              tooltipText: "Forward " + root.skipForward + " seconds (→)"
              enabled: root.playerState !== "ended"
              onClicked: root.podcasts.skip(root.skipForward)
            }
          }

          // The speed choices, shown under the buttons while the speed button
          // is open; picking one applies it and closes the row.
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(6)
            visible: root.speedOpen
            Repeater {
              model: root.speedChoices
              Button {
                required property var modelData
                text: Model.formatSpeed(modelData)
                selected: modelData === root.speed
                onClicked: { root.podcasts.setSpeed(modelData); root.speedOpen = false }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.playError !== ""
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.playError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: "Space play/pause · ←/→ skip · o open in Apple Podcasts · s stop"
          }
        }

        // ---------------------------------------------------------------- list
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.signedIn && !root.showAccount && !root.showPlayer

          // What is playing: a card pinned above the list, with transport
          // controls so it can be paused or skipped without opening the player.
          Rectangle {
            width: parent.width
            height: nowColumn.implicitHeight + Style.space(20)
            radius: Style.space(8)
            visible: root.nowPlaying !== null
            color: Qt.alpha(root.accent, 0.18)
            border.width: 1
            border.color: root.accent

            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.playerOpen = true }

            Column {
              id: nowColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(10)
              spacing: Style.space(6)

              Text {
                width: parent.width
                text: root.playerState === "paused" ? "PAUSED" : root.playerState === "ended" ? "FINISHED"
                  : root.playerState === "buffering" ? "LOADING…" : "NOW PLAYING"
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.nowPlaying ? root.nowPlaying.title : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                visible: text !== ""
                text: root.nowPlaying ? root.nowPlaying.show : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Rectangle {
                width: parent.width
                height: Style.space(3)
                radius: height / 2
                color: Qt.alpha(root.foreground, 0.2)
                Rectangle {
                  width: root.duration > 0 ? parent.width * Math.min(1, root.position / root.duration) : 0
                  height: parent.height
                  radius: parent.radius
                  color: root.accent
                }
              }
              Row {
                spacing: Style.space(8)
                Button {
                  iconText: root.playerState === "ended" ? "" : root.isPlaying ? "" : root.playerState === "buffering" ? "" : ""
                  iconSpinning: root.playerState === "buffering"
                  tooltipText: root.playerState === "ended" ? "Replay" : root.isPlaying ? "Pause" : "Play"
                  onClicked: root.podcasts.togglePlay()
                }
                Button {
                  text: "+30s"
                  tooltipText: "Forward 30 seconds"
                  enabled: root.playerState !== "ended"
                  onClicked: root.podcasts.skip(30)
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: Model.formatClock(root.position) + (root.duration > 0 ? " / " + Model.formatClock(root.duration) : "")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.playError !== "" && !root.showPlayer
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.playError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width
            visible: root.errorText !== ""
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: root.errorText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width
            visible: root.episodes.length === 0 && !root.loading && root.errorText === ""
            text: "No episodes."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Repeater {
            model: root.episodes

            Rectangle {
              id: row
              required property int index
              required property var modelData
              width: parent.width
              height: rowText.implicitHeight + Style.space(12)
              radius: Style.space(6)
              color: row.index === root.selected ? Qt.alpha(root.accent, 0.18) : "transparent"

              Column {
                id: rowText
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Style.space(8)
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: row.modelData.title
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  text: [row.modelData.show, Model.relativeAge(row.modelData.published),
                    Model.formatDuration(row.modelData.durationMs),
                    Model.resumeLabel(root.podcasts.positions[row.modelData.id], row.modelData.durationMs)].filter(function(s) { return s !== "" }).join(" · ")
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: root.selected = row.index
                onClicked: root.openEpisode(row.index)
              }
            }
          }
        }

        // -------------------------------------------------------------- footer
        Row {
          spacing: Style.space(14)
          visible: root.signedIn && !root.showPlayer
          Text {
            text: root.loading ? "Refreshing…" : "r Refresh"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            text: root.showAccount ? "c Back" : "c Account"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }
}
