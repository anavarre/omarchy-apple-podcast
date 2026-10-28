.pragma library

// Pure helpers shared by Service.qml, Panel.qml and BarWidget.qml, kept free of
// QML types so they can be unit-tested with node (tests/model.test.js).

var episodeLimitMin = 1
var episodeLimitMax = 50
var refreshChoices = [30, 60, 120, 180, 360, 720, 1440]
var sources = ["latest", "up-next"]
// The skip lengths Apple's own clients offer.
// Playback speeds on offer, slowest first.
var speedChoices = [0.8, 1, 1.3, 1.5, 1.8, 2]
var skipChoices = [10, 15, 30, 45, 60, 75, 90]

// The environment bin/podcasts-api is run with. A null value means "inherit
// this one from the shell"; everything else is dropped (clearEnvironment).
var environment = {
  PATH: "/usr/bin:/bin",
  HOME: null,
  XDG_CONFIG_HOME: null,
  PODCASTS_PLUGIN_DIR: null,
  PODCASTS_API_BASE: null,
  PODCASTS_PLAYER_DIR: null,
  PODCASTS_MPV_AO: null,
  XDG_RUNTIME_DIR: null,
  PULSE_SERVER: null,
  PULSE_RUNTIME_PATH: null,
  PIPEWIRE_RUNTIME_DIR: null,
  PODCASTS_WEB_BASE: null,
  https_proxy: null,
  HTTPS_PROXY: null,
  http_proxy: null,
  all_proxy: null,
  ALL_PROXY: null,
  no_proxy: null,
  NO_PROXY: null,
  SSL_CERT_FILE: null,
  SSL_CERT_DIR: null,
  CURL_CA_BUNDLE: null
}

function localPath(url) {
  var s = String(url || "")
  if (s.indexOf("file://") !== 0) return ""
  try {
    return decodeURIComponent(s.slice("file://".length))
  } catch (e) {
    return ""
  }
}

function text(value) {
  return value === undefined || value === null ? "" : String(value)
}

function clampEpisodeLimit(value) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) return 10
  return Math.max(episodeLimitMin, Math.min(episodeLimitMax, n))
}

function snapRefreshMinutes(value) {
  var n = Number(value)
  if (!isFinite(n)) return refreshChoices[0]
  for (var i = 0; i < refreshChoices.length; i++)
    if (refreshChoices[i] >= n) return refreshChoices[i]
  return refreshChoices[refreshChoices.length - 1]
}

function knownSkip(value, fallback) {
  var n = Number(value)
  return skipChoices.indexOf(n) >= 0 ? n : fallback
}

function knownSpeed(value) {
  var n = Number(value)
  return speedChoices.indexOf(n) >= 0 ? n : 1
}

// 1 -> "x1", 1.3 -> "x1,3": decimal comma, as the speeds are written for this plugin.
function formatSpeed(value) {
  return "x" + String(knownSpeed(value)).replace(".", ",")
}

function knownSource(value) {
  return sources.indexOf(value) >= 0 ? value : "latest"
}

// bin/podcasts-api prints the response body, then a final line "HTTP <status>".
function splitResponse(out) {
  var s = text(out)
  var cut = s.lastIndexOf("\nHTTP ")
  var head = cut >= 0 ? s.slice(0, cut) : ""
  var tail = cut >= 0 ? s.slice(cut + 1) : s
  var m = /^HTTP (\d{3})\s*$/.exec(tail)
  if (!m) return { status: 0, body: s }
  return { status: Number(m[1]), body: head }
}

// Apple's amp-api answers { data: [ { id, type, attributes: {...} } ] }. The
// attribute names below are the ones the web app reads; each has a fallback so
// a renamed field degrades to a blank rather than an exception.
function artworkUrl(artwork, size) {
  var u = artwork && artwork.url ? String(artwork.url) : ""
  return u.replace("{w}", size).replace("{h}", size).replace("{f}", "jpg")
}

function normalizeEpisode(item) {
  var a = (item && item.attributes) || {}
  var date = a.releaseDateTime || a.releaseDate || a.datePublished || ""
  return {
    id: text(item && item.id),
    title: text(a.name || a.title),
    show: text(a.artistName || a.showName || a.collectionName),
    published: text(date),
    url: text(a.url || a.websiteUrl),
    artwork: artworkUrl(a.artwork, 80),
    artworkLarge: artworkUrl(a.artwork, 300),
    // The publisher's own audio file. Absent for some subscriber-only shows.
    assetUrl: text(a.assetUrl),
    durationMs: Number(a.durationInMilliseconds || 0) || 0
  }
}

// Returns { ok, episodes, error }. Anything that is not the expected envelope
// is an error rather than an empty list, so a schema change is visible.
function parseEpisodes(body) {
  var json
  try { json = JSON.parse(text(body)) } catch (e) {
    return { ok: false, episodes: [], error: "Apple returned something that is not JSON." }
  }
  if (!json || !Array.isArray(json.data))
    return { ok: false, episodes: [], error: "Apple's answer had no episode list; the web API may have changed." }
  var out = []
  for (var i = 0; i < json.data.length; i++) {
    var e = normalizeEpisode(json.data[i])
    if (e.title !== "" || e.id !== "") out.push(e)
  }
  return { ok: true, episodes: out, error: "" }
}

// bin/podcasts-api positions answers { data: [ { id, attributes: {
// positionInMilliseconds, completed, recordedAtTimestamp } } ] }: where each
// episode was left, on whichever device. Returns { id: { ms, completed } }; an
// episode Apple has no position for is simply absent.
function parsePositions(body) {
  var json
  try { json = JSON.parse(text(body)) } catch (e) { return null }
  if (!json || !Array.isArray(json.data)) return null
  var out = {}
  for (var i = 0; i < json.data.length; i++) {
    var item = json.data[i], a = (item && item.attributes) || {}
    var ms = Number(a.positionInMilliseconds)
    if (item && item.id) out[String(item.id)] = { ms: isFinite(ms) && ms > 0 ? ms : 0, completed: a.completed === true }
  }
  return out
}

// Apple's own clients call anything under 15 s "unstarted" and a finished
// episode starts over, so those resume from 0. So does a position within the
// last 10 s of a known duration (nothing worth resuming).
var resumeFloorSeconds = 15
var resumeTailSeconds = 10
function resumeSeconds(pos, durationMs) {
  if (!pos || pos.completed) return 0
  var s = Math.floor(Number(pos.ms) / 1000)
  if (!isFinite(s) || s <= resumeFloorSeconds) return 0
  var dur = Number(durationMs) / 1000
  if (dur > 0 && s >= dur - resumeTailSeconds) return 0
  return s
}

// Whether playback that reached `seconds` of `duration` counts as finished.
function isFinished(seconds, duration) {
  return Number(duration) > 0 && Number(seconds) >= Number(duration) - resumeTailSeconds
}

// "Resumes at 25:26" / "Played", for an episode row; "" when there is nothing to say.
function resumeLabel(pos, durationMs) {
  if (!pos) return ""
  if (pos.completed) return "Played"
  var s = resumeSeconds(pos, durationMs)
  return s > 0 ? "At " + formatClock(s) : ""
}

function relativeAge(iso, now) {
  var t = Date.parse(text(iso))
  if (!isFinite(t)) return ""
  var secs = Math.max(0, Math.round(((now === undefined ? Date.now() : now) - t) / 1000))
  if (secs < 3600) return Math.max(1, Math.round(secs / 60)) + "m ago"
  if (secs < 86400) return Math.round(secs / 3600) + "h ago"
  if (secs < 86400 * 30) return Math.round(secs / 86400) + "d ago"
  return Math.round(secs / 86400 / 30) + "mo ago"
}

function formatDuration(ms) {
  var mins = Math.round(Number(ms) / 60000)
  if (!isFinite(mins) || mins <= 0) return ""
  return mins >= 60 ? Math.floor(mins / 60) + "h " + (mins % 60) + "m" : mins + "m"
}

// A message for a failed request, from the script's exit code and the HTTP
// status (see the exit codes at the top of bin/podcasts-api).
function isAuthFailure(exitCode, status) {
  return exitCode === 12 || exitCode === 21 || status === 401 || status === 403
}

function isTransient(exitCode, status) {
  return exitCode === 20 || status === 0 || status >= 500 || status === 429
}

function errorMessage(stderr, exitCode, status) {
  var s = text(stderr).trim().slice(0, 200)
  if (isAuthFailure(exitCode, status))
    return "Apple rejected the stored session. Sign in again."
  if (exitCode === 25) return s || "Could not read Apple's web player to get its access token."
  if (isTransient(exitCode, status)) return s || "Could not reach Apple Podcasts."
  return s || "Apple Podcasts answered with HTTP " + status + "."
}

// 3725 -> "1:02:05", 65 -> "1:05", for the player's clock.
function formatClock(seconds) {
  var n = Math.max(0, Math.floor(Number(seconds)))
  if (!isFinite(n)) return "0:00"
  var h = Math.floor(n / 3600)
  var m = Math.floor((n % 3600) / 60)
  var s = n % 60
  var ss = (s < 10 ? "0" : "") + s
  return h > 0 ? h + ":" + (m < 10 ? "0" : "") + m + ":" + ss : m + ":" + ss
}

// bin/podcasts-player status prints one JSON object; anything else is no
// player. Numbers are clamped so a half-loaded stream cannot show NaN.
function parseStatus(out) {
  var j
  try { j = JSON.parse(text(out)) } catch (e) { return null }
  if (!j || typeof j !== "object") return null
  var pos = Number(j.position), dur = Number(j.duration)
  return {
    position: isFinite(pos) && pos > 0 ? pos : 0,
    duration: isFinite(dur) && dur > 0 ? dur : 0,
    paused: j.paused === true,
    buffering: j.buffering === true,
    speed: knownSpeed(j.speed),
    title: text(j.title)
  }
}

function playMessage(stderr, exitCode) {
  var s = text(stderr).trim().slice(0, 200)
  if (exitCode === 31) return "mpv could not start playing that episode."
  if (exitCode === 24) return s || "No safe place for the player's socket."
  return s || "Playback failed (exit " + exitCode + ")."
}
