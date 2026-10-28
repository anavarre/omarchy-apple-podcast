const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const vm = require("node:vm");

// Model.js is a QML .pragma library; evaluate it as a plain script.
const ctx = {};
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(__dirname + "/../Model.js", "utf8").replace(/^\.pragma.*$/m, ""), ctx);
const M = ctx;

test("clampEpisodeLimit", () => {
  assert.strictEqual(M.clampEpisodeLimit(0), 1);
  assert.strictEqual(M.clampEpisodeLimit(999), 50);
  assert.strictEqual(M.clampEpisodeLimit("x"), 10);
  assert.strictEqual(M.clampEpisodeLimit(7.4), 7);
});

test("snapRefreshMinutes", () => {
  assert.strictEqual(M.snapRefreshMinutes(1), 30);
  assert.strictEqual(M.snapRefreshMinutes(45), 60);
  assert.strictEqual(M.snapRefreshMinutes(99999), 1440);
});

test("splitResponse", () => {
  assert.deepStrictEqual({ ...M.splitResponse('{"a":1}\nHTTP 200\n') }, { status: 200, body: '{"a":1}' });
  assert.strictEqual(M.splitResponse("garbage").status, 0);
});

test("parseEpisodes", () => {
  const body = JSON.stringify({ data: [{ id: "1", attributes: { name: "T", artistName: "S",
    releaseDateTime: "2026-10-27T08:00:00Z", url: "u", durationInMilliseconds: 1800000,
    artwork: { url: "a/{w}x{h}.{f}" } } }] });
  const r = M.parseEpisodes(body);
  assert.strictEqual(r.ok, true);
  assert.strictEqual(r.episodes[0].title, "T");
  assert.strictEqual(r.episodes[0].show, "S");
  assert.strictEqual(r.episodes[0].artwork, "a/80x80.jpg");
  assert.strictEqual(M.parseEpisodes("nope").ok, false);
  assert.strictEqual(M.parseEpisodes('{"x":1}').ok, false);
  assert.strictEqual(M.parseEpisodes('{"data":[]}').episodes.length, 0);
});

test("relativeAge and formatDuration", () => {
  const now = Date.parse("2026-10-28T12:00:00Z");
  assert.strictEqual(M.relativeAge("2026-10-28T11:30:00Z", now), "30m ago");
  assert.strictEqual(M.relativeAge("2026-10-27T12:00:00Z", now), "1d ago");
  assert.strictEqual(M.relativeAge("nope", now), "");
  assert.strictEqual(M.formatDuration(5400000), "1h 30m");
  assert.strictEqual(M.formatDuration(0), "");
});

test("errorMessage", () => {
  assert.match(M.errorMessage("", 21, 403), /Sign in again/);
  assert.match(M.errorMessage("", 20, 0), /reach Apple/);
});

test("player helpers", () => {
  assert.strictEqual(M.formatClock(65), "1:05");
  assert.strictEqual(M.formatClock(3725), "1:02:05");
  assert.strictEqual(M.formatClock(-4), "0:00");
  assert.strictEqual(M.knownSkip(15, 30), 15);
  assert.strictEqual(M.knownSkip(7, 30), 30);
  const st = M.parseStatus('{"position":12.5,"duration":60,"paused":true,"buffering":false,"title":"T"}');
  assert.strictEqual(st.position, 12.5);
  assert.strictEqual(st.paused, true);
  assert.strictEqual(st.title, "T");
  assert.strictEqual(M.parseStatus("nope"), null);
  assert.strictEqual(M.parseStatus('{"position":null,"duration":-1}').position, 0);
  const ep = M.parseEpisodes(JSON.stringify({ data: [{ id: "1", attributes: { name: "T", assetUrl: "https://a/b.mp3",
    artwork: { url: "x/{w}x{h}.{f}" } } }] })).episodes[0];
  assert.strictEqual(ep.assetUrl, "https://a/b.mp3");
  assert.strictEqual(ep.artworkLarge, "x/300x300.jpg");
});

test("speed helpers", () => {
  assert.strictEqual(M.formatSpeed(1), "x1");
  assert.strictEqual(M.formatSpeed(1.3), "x1,3");
  assert.strictEqual(M.formatSpeed(0.8), "x0,8");
  assert.strictEqual(M.formatSpeed(7), "x1");
  assert.strictEqual(M.parseStatus('{"speed":1.5}').speed, 1.5);
  assert.strictEqual(M.parseStatus('{}').speed, 1);
});

test("positions and resuming", () => {
  const body = JSON.stringify({ data: [
    { id: "1", attributes: { positionInMilliseconds: 754000, completed: false } },
    { id: "2", attributes: { positionInMilliseconds: 1800000, completed: true } },
    { id: "3", attributes: { completed: false } }] });
  const p = M.parsePositions(body);
  assert.strictEqual(p["1"].ms, 754000);
  assert.strictEqual(p["2"].completed, true);
  assert.strictEqual(p["3"].ms, 0);
  assert.strictEqual(M.parsePositions("nope"), null);
  assert.strictEqual(M.parsePositions('{"x":1}'), null);
  assert.strictEqual(Object.keys(M.parsePositions('{"data":[]}')).length, 0);
  assert.strictEqual(M.resumeSeconds(p["1"], 1800000), 754);
  assert.strictEqual(M.resumeSeconds(p["2"], 1800000), 0);    // finished: from the top
  assert.strictEqual(M.resumeSeconds({ ms: 9000, completed: false }, 1800000), 0);  // barely started
  assert.strictEqual(M.resumeSeconds({ ms: 1795000, completed: false }, 1800000), 0);  // in the tail
  assert.strictEqual(M.resumeSeconds({ ms: 1795000, completed: false }, 0), 1795);  // unknown length
  assert.strictEqual(M.resumeSeconds(undefined, 1800000), 0);
  assert.strictEqual(M.isFinished(1795, 1800), true);
  assert.strictEqual(M.isFinished(1700, 1800), false);
  assert.strictEqual(M.isFinished(100, 0), false);
  assert.strictEqual(M.resumeLabel(p["1"], 1800000), "At 12:34");
  assert.strictEqual(M.resumeLabel(p["2"], 1800000), "Played");
  assert.strictEqual(M.resumeLabel(undefined, 1800000), "");
});
