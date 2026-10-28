import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The one process-wide owner of everything fetched from Apple Podcasts: sign-in
// state, the episode list and the refresh timer. The bar widget exists once per
// monitor; they all read this instead of polling on their own.
Item {
  id: root

  // Injected by the host after load.
  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  readonly property string api: Model.localPath(Qt.resolvedUrl("bin/podcasts-api"))
  readonly property string player: Model.localPath(Qt.resolvedUrl("bin/podcasts-player"))

  // Pushed in by the bar widget, the only side the shell injects settings into.
  property int episodeLimit: 10
  property int refreshMinutes: 60
  property string source: "latest"
  // Seconds the skip buttons jump, from the lengths Apple's clients offer.
  property int skipBackSeconds: 15
  property int skipForwardSeconds: 15

  // "unknown" until the first check, then "ok" or "signedOut". "offline" means
  // the request never got through: that keeps the list up rather than asking
  // for a sign-in nothing rejected.
  property string authState: "unknown"
  property bool hasToken: false
  property string storeDir: ""
  property bool loading: false
  property bool saving: false
  property string errorText: ""
  property string signInError: ""
  property var episodes: []
  // Where each listed episode was left, on any device: { id: { ms, completed } }
  // (Model.parsePositions). Playing an episode asks Apple again, so this only
  // has to be good enough to label the list.
  property var positions: ({})
  readonly property bool authenticated: authState === "ok"

  // Bumped on sign-in and forget so a result fetched under old credentials
  // never lands after them.
  property int session: 0
  property bool refreshQueued: false

  onEpisodeLimitChanged: refreshSoon()
  onSourceChanged: refreshSoon()
  onRefreshMinutesChanged: timer.restart()

  function refreshSoon() { if (authState === "ok") Qt.callLater(refresh) }

  function checkConfig() {
    if (configProcess.running) return
    configProcess.command = ["/usr/bin/bash", root.api, "config"]
    configProcess.running = true
  }

  function refresh() {
    if (!root.hasToken) { root.checkConfig(); return }
    if (episodesProcess.running) { root.refreshQueued = true; return }
    root.loading = true
    episodesProcess.session = root.session
    episodesProcess.command = ["/usr/bin/bash", root.api, "episodes",
      String(Model.clampEpisodeLimit(root.episodeLimit)), Model.knownSource(root.source)]
    episodesProcess.running = true
  }

  // Stores the pasted media-user-token, then loads the list with it.
  function signIn(token) {
    if (saveProcess.running) return
    root.saving = true
    root.signInError = ""
    saveProcess.session = ++root.session
    saveProcess.payload = String(token || "").replace(/[\r\n]/g, "").trim() + "\n"
    saveProcess.command = ["/usr/bin/bash", root.api, "save"]
    saveProcess.stdinEnabled = true
    saveProcess.running = true
  }

  function forget() {
    root.session++
    forgetProcess.command = ["/usr/bin/bash", root.api, "forget"]
    forgetProcess.running = true
    root.hasToken = false
    root.authState = "signedOut"
    root.episodes = []
    root.positions = ({})
    root.pushedKey = ""
    root.pendingPush = null
    root.errorText = ""
  }

  function refreshPositions() {
    if (!root.hasToken || positionsProcess.running || root.episodes.length === 0) return
    var ids = root.episodes.slice(0, 30).map(function(e) { return e.id }).filter(function(id) { return /^[0-9]+$/.test(id) })
    if (ids.length === 0) return
    positionsProcess.session = root.session
    positionsProcess.command = ["/usr/bin/bash", root.api, "positions", ids.join(",")]
    positionsProcess.running = true
  }

  function openUrl(url) { if (url) Qt.openUrlExternally(url) }

  // ---------------------------------------------------------------- playback
  // The episode being played, or null. "idle" until something is started, then
  // "buffering", "playing", "paused" or "ended" (mpv exited: the episode ran
  // out, or was stopped).
  property var nowPlaying: null
  property string playerState: "idle"
  property real position: 0
  property real duration: 0
  property string playError: ""
  // Kept across episodes and restarts (the player script stores it), so a
  // chosen speed sticks until it is changed.
  property real speed: 1
  // Whether a panel is showing the player, which is when a once-a-second
  // clock is worth the process it costs.
  property bool playerVisible: false
  readonly property bool playbackActive: nowPlaying !== null
    && (playerState === "playing" || playerState === "paused" || playerState === "buffering")

  // Control commands (toggle, seek, stop) run one after another, so a quick
  // second press of a skip button is queued instead of dropped.
  property var controlQueue: []

  // True from the click on an episode until mpv is up: Apple is asked where you
  // left off first, and the old audio's clock must not be read as the new one's.
  property bool starting: false
  // The last position Apple accepted ("id:ms:done"), when it was sent, and one
  // waiting for the request in flight to finish.
  property string pushedKey: ""
  property real lastPushAt: 0
  property var pendingPush: null
  readonly property int pushEveryMs: 15000

  function sameEpisode(a, b) { return a && b && a.id !== "" && a.id === b.id }

  function play(episode) {
    if (!episode) return
    if (root.sameEpisode(root.nowPlaying, episode) && root.playbackActive) return
    if (!episode.assetUrl) {
      root.playError = "Apple lists no audio file for this episode (it may be subscriber-only)."
      return
    }
    root.playError = ""
    // Leave the episode being replaced where it got to, and silence it now
    // rather than after the lookup below.
    if (root.playbackActive && !root.sameEpisode(root.nowPlaying, episode)) {
      root.pushPosition()
      root.control(["stop"])
    }
    root.nowPlaying = episode
    root.playerState = "buffering"
    root.position = 0
    root.duration = Number(episode.durationMs) / 1000 || 0
    root.starting = true
    root.fetchResume()
  }

  // Asks Apple where the episode being started was left (on the phone, say) and
  // starts it there. Any failure just means starting from the top.
  function fetchResume() {
    var e = root.nowPlaying
    if (!e || resumeProcess.running) return
    resumeProcess.episode = e
    if (!/^[0-9]+$/.test(e.id) || !root.hasToken) { root.launch(e, 0); return }
    resumeProcess.command = ["/usr/bin/bash", root.api, "positions", e.id]
    resumeProcess.running = true
  }

  function launch(episode, seconds) {
    root.position = seconds
    playProcess.command = ["/usr/bin/bash", root.player, "play", episode.assetUrl, episode.title, String(seconds)]
    playProcess.running = true
  }

  // Tells Apple how far the current episode has got, so that the phone and any
  // other device resume from here. An episode adopted after a shell reload has no
  // id and is not reported. Skips what Apple already has.
  function pushPosition() {
    var e = root.nowPlaying
    if (!e || !/^[0-9]+$/.test(e.id) || !root.hasToken || root.starting) return
    if (root.playerState !== "playing" && root.playerState !== "paused" && root.playerState !== "ended") return
    var done = Model.isFinished(root.position, root.duration)
    var ms = Math.round((done ? root.duration : root.position) * 1000)
    if (ms <= 0) return
    var key = e.id + ":" + ms + ":" + done
    if (key === root.pushedKey) return
    root.pendingPush = { id: e.id, ms: ms, done: done, key: key }
    root.flushPush()
  }

  function flushPush() {
    if (putProcess.running || !root.pendingPush) return
    putProcess.sent = root.pendingPush
    root.pendingPush = null
    root.lastPushAt = Date.now()
    putProcess.command = ["/usr/bin/bash", root.api, "setposition", putProcess.sent.id,
      String(putProcess.sent.ms), putProcess.sent.done ? "true" : "false"]
    putProcess.running = true
  }

  function togglePlay() {
    if (!root.nowPlaying) return
    if (root.playerState === "ended") { root.replay(); return }
    root.playerState = root.playerState === "paused" ? "playing" : "paused"
    root.control(["toggle"])
  }

  // Seconds relative to now; negative goes back. The clock moves at once and
  // the next status poll corrects it.
  function skip(seconds) {
    if (!root.playbackActive) return
    root.position = Math.max(0, Math.min(root.duration > 0 ? root.duration : 1e9, root.position + seconds))
    root.control(["seek", String(Math.round(seconds))])
  }

  function seekTo(seconds) {
    if (!root.playbackActive) return
    root.position = Math.max(0, seconds)
    root.control(["seekto", String(Math.round(Math.max(0, seconds)))])
  }

  function setSpeed(rate) {
    root.speed = Model.knownSpeed(rate)
    root.control(["speed", String(root.speed)])
  }

  function replay() {
    var e = root.nowPlaying
    if (!e || !e.assetUrl) return
    root.nowPlaying = null
    root.play(e)
  }

  function stopPlayback() {
    if (root.playbackActive) root.pushPosition()
    root.starting = false
    root.controlQueue = []
    controlProcess.command = ["/usr/bin/bash", root.player, "stop"]
    controlProcess.running = true
    root.nowPlaying = null
    root.playerState = "idle"
    root.position = 0
    root.duration = 0
  }

  function control(args) {
    root.controlQueue = root.controlQueue.concat([args])
    root.nextControl()
  }

  function nextControl() {
    if (controlProcess.running || root.controlQueue.length === 0) return
    var args = root.controlQueue[0]
    root.controlQueue = root.controlQueue.slice(1)
    controlProcess.command = ["/usr/bin/bash", root.player].concat(args)
    controlProcess.running = true
  }

  function pollPlayer() {
    if (statusProcess.running || playProcess.running || root.starting) return
    statusProcess.command = ["/usr/bin/bash", root.player, "status"]
    statusProcess.running = true
  }

  // On load, also look for audio still running from before a shell reload:
  // mpv is detached, so it outlives us.
  Component.onCompleted: { root.checkConfig(); root.loadSpeed(); root.pollPlayer() }

  function loadSpeed() {
    speedProcess.command = ["/usr/bin/bash", root.player, "getspeed"]
    speedProcess.running = true
  }

  Timer {
    id: timer
    interval: Model.snapRefreshMinutes(root.refreshMinutes) * 60000
    repeat: true
    running: root.authState === "ok" || root.authState === "offline"
    onTriggered: root.refresh()
  }

  // Polls mpv while there is something to show: every second with the player
  // up, every few seconds otherwise, so playback ending is still noticed.
  Timer {
    interval: root.playerVisible ? 1000 : 5000
    repeat: true
    running: root.nowPlaying !== null && root.playerState !== "ended"
    onTriggered: root.pollPlayer()
  }

  Process {
    id: playProcess
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stderr: StdioCollector { id: playErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.starting = false
      if (exitCode !== 0) {
        root.playError = Model.playMessage(playErr.text, exitCode)
        root.nowPlaying = null
        root.playerState = "idle"
        return
      }
      // mpv was started at the remembered speed; this keeps it in step.
      root.control(["speed", String(root.speed)])
      root.pollPlayer()
    }
  }

  Process {
    id: speedProcess
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: speedOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0 && !root.nowPlaying) root.speed = Model.knownSpeed(speedOut.text.trim())
    }
  }

  Process {
    id: controlProcess
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    onExited: function(exitCode) {
      if (root.controlQueue.length > 0) Qt.callLater(root.nextControl)
      else Qt.callLater(root.pollPlayer)
    }
  }

  Process {
    id: statusProcess
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function(exitCode) {
      var st = exitCode === 0 ? Model.parseStatus(statusOut.text) : null
      if (!st) {
        // mpv is gone. If we were playing, the episode is over (or was
        // stopped from outside); keep it on screen so it can be replayed.
        if (root.nowPlaying && root.playerState !== "idle" && root.playerState !== "buffering") {
          root.playerState = "ended"
          root.pushPosition()
        }
        return
      }
      var adopted = !root.nowPlaying
      if (adopted)
        // Adopted after a shell reload: all that is known is the title.
        root.nowPlaying = { id: "", title: st.title, show: "", published: "", url: "",
          artwork: "", artworkLarge: "", assetUrl: "", durationMs: 0 }
      root.position = st.position
      // Our speed is the setting; mpv's only wins for audio adopted after a reload.
      if (adopted) root.speed = st.speed
      if (st.duration > 0) root.duration = st.duration
      root.playerState = st.buffering ? "buffering" : st.paused ? "paused" : "playing"
      if (root.playerState === "paused" || (root.playerState === "playing" && Date.now() - root.lastPushAt >= root.pushEveryMs))
        root.pushPosition()
    }
  }

  Process {
    id: configProcess
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: configOut; waitForEnd: true }
    onExited: function(exitCode) {
      var info = {}
      try { info = JSON.parse(configOut.text) } catch (e) { info = {} }
      root.hasToken = info.hasToken === true
      root.storeDir = Model.text(info.store)
      if (root.hasToken) root.refresh()
      else root.authState = "signedOut"
    }
  }

  Process {
    id: saveProcess
    property int session: 0
    property string payload: ""
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdinEnabled: true
    stderr: StdioCollector { id: saveErr; waitForEnd: true }
    onStarted: {
      write(payload)
      payload = ""
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      root.saving = false
      if (saveProcess.session !== root.session) return
      if (exitCode !== 0) {
        root.signInError = Model.text(saveErr.text).trim().slice(0, 200) || "Could not store the token."
        return
      }
      root.hasToken = true
      root.authState = "unknown"
      root.refresh()
    }
  }

  Process {
    id: forgetProcess
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
  }

  Process {
    id: resumeProcess
    property var episode: null
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: resumeOut; waitForEnd: true }
    onExited: function(exitCode) {
      var e = root.nowPlaying
      // Stopped meanwhile: nothing to start. Another episode picked: look that one up.
      if (!e || !root.starting) return
      if (e !== resumeProcess.episode) { root.fetchResume(); return }
      var response = Model.splitResponse(resumeOut.text)
      var found = exitCode === 0 && response.status === 200 ? Model.parsePositions(response.body) : null
      var pos = found ? found[e.id] : null
      if (found) {
        var next = Object.assign({}, root.positions)
        if (pos) next[e.id] = pos
        root.positions = next
      }
      root.launch(e, Model.resumeSeconds(pos, e.durationMs))
    }
  }

  Process {
    id: putProcess
    property var sent: null
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: putOut; waitForEnd: true }
    onExited: function(exitCode) {
      var status = Model.splitResponse(putOut.text).status
      if (exitCode === 0 && status >= 200 && status < 300 && putProcess.sent) {
        var s = putProcess.sent
        root.pushedKey = s.key
        var next = Object.assign({}, root.positions)
        next[s.id] = { ms: s.ms, completed: s.done }
        root.positions = next
      }
      // A failure is retried by the next push, which finds the key unsent.
      if (root.pendingPush) Qt.callLater(root.flushPush)
    }
  }

  Process {
    id: positionsProcess
    property int session: 0
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: positionsOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (positionsProcess.session !== root.session) return
      var response = Model.splitResponse(positionsOut.text)
      var found = exitCode === 0 && response.status === 200 ? Model.parsePositions(response.body) : null
      if (found) root.positions = Object.assign({}, root.positions, found)
    }
  }

  Process {
    id: episodesProcess
    property int session: 0
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: episodesOut; waitForEnd: true }
    stderr: StdioCollector { id: episodesErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.loading = false
      var stale = episodesProcess.session !== root.session
      var response = Model.splitResponse(episodesOut.text)
      if (!stale) {
        if (Model.isAuthFailure(exitCode, response.status)) {
          root.authState = "signedOut"
          root.signInError = Model.errorMessage(episodesErr.text, exitCode, response.status)
          root.episodes = []
        } else if (exitCode === 0 && response.status === 200) {
          var parsed = Model.parseEpisodes(response.body)
          root.authState = "ok"
          if (parsed.ok) { root.episodes = parsed.episodes; root.errorText = ""; root.refreshPositions() }
          else root.errorText = parsed.error
        } else {
          root.authState = Model.isTransient(exitCode, response.status) ? "offline" : "ok"
          root.errorText = Model.errorMessage(episodesErr.text, exitCode, response.status)
        }
      }
      if (root.refreshQueued) { root.refreshQueued = false; Qt.callLater(root.refresh) }
    }
  }
}
