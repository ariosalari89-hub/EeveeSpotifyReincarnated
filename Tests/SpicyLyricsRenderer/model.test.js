"use strict";

const assert = require("node:assert/strict");
const model = require("../../layout/Library/Application Support/EeveeSpotify.bundle/SpicyLyricsRenderer/renderer-model.js");

function session(overrides = {}, now = 1000) {
  return model.normalizeSession({
    generation: "1",
    sequence: "1",
    trackId: "track-a",
    positionMs: 10_000,
    durationMs: 180_000,
    playbackRate: 1,
    isPlaying: true,
    isPaused: false,
    isAdvancing: true,
    shuffleEnabled: false,
    repeatMode: "off",
    track: { id: "track-a", title: "Song A", artist: "Artist" },
    ...overrides
  }, now);
}

// Atomic session ordering: no late callback from an old generation or old
// sequence can combine a prior song with the current renderer.
const current = session({ generation: "8", sequence: "14", trackId: "new" });
assert.equal(model.shouldAcceptSession(current, { generation: "7", sequence: "999", trackId: "old" }), false);
assert.equal(model.shouldAcceptSession(current, { generation: "8", sequence: "13", trackId: "new" }), false);
assert.equal(model.shouldAcceptSession(current, { generation: "8", sequence: "15", trackId: "wrong" }), false);
assert.equal(model.shouldAcceptSession(current, { generation: "9", sequence: "1", trackId: "next" }), true);
assert.equal(model.compareOrdinal("18446744073709551614", "18446744073709551613"), 1);

// The first render starts at the observed audible position and advances from
// the receipt instant. Paused, loading, buffering, and lifecycle-frozen clocks
// never drift.
const playing = session({ positionMs: 42_000 }, 500);
assert.equal(model.projectedPosition(playing, 1250), 42_750);
const paused = session({ positionMs: 42_750, isPlaying: false, isPaused: true, isAdvancing: false }, 1250);
assert.equal(model.projectedPosition(paused, 50_000), 42_750);
const buffering = session({ positionMs: 44_000, isBuffering: true, isAdvancing: false }, 2000);
assert.equal(model.projectedPosition(buffering, 50_000), 44_000);
assert.equal(model.renderedPosition({
  session: playing,
  now: 9000,
  lifecycleFrozen: true,
  frozenPositionMs: 43_125
}), 43_125);

// Seek has one local preview. Old observations remain truthful in state but do
// not snap the thumb/lyrics backwards while Spotify is applying the command.
let preview = model.beginSeekPreview(70_000, playing, 1300);
assert.equal(model.renderedPosition({ session: playing, now: 1400, seekPreview: preview }), 70_000);
preview = model.acknowledgeSeekPreview(preview, true);
preview = model.reconcileSeekPreview(preview, session({ sequence: "2", positionMs: 43_000 }, 1400), 1400);
assert.ok(preview, "an old post-command sample must not snap back the preview");
preview = model.reconcileSeekPreview(preview, session({ sequence: "3", positionMs: 69_650 }, 1500), 1500);
assert.equal(preview, null, "a confirmed observed seek must release preview");
let refused = model.acknowledgeSeekPreview(model.beginSeekPreview(90_000, playing, 1000), false);
assert.equal(model.reconcileSeekPreview(refused, playing, 1100), null);
let timedOut = model.beginSeekPreview(90_000, playing, 1000, 600);
assert.equal(model.reconcileSeekPreview(timedOut, playing, 1601), null);

// Commands are complete only when the observed player state demonstrates the
// effect. Dispatch acknowledgement alone is intentionally insufficient.
assert.equal(model.commandObserved("pause", playing, paused), true);
assert.equal(model.commandObserved("play", paused, playing), true);
assert.equal(model.commandObserved("next", playing, session({ generation: "2", trackId: "track-b" })), true);
assert.equal(model.commandObserved("previous", playing, session({ positionMs: 100, sequence: "2" })), true);
assert.equal(model.commandObserved("toggleShuffle", playing, session({ shuffleEnabled: true, sequence: "2" })), true);
const smart = session({shuffleMode:"smart",shuffleEnabled:true,smartShuffleAvailable:true});
assert.equal(model.commandObserved("toggleShuffle", smart, session({shuffleMode:"shuffle",sequence:"2"})), false);
assert.equal(model.commandObserved("toggleShuffle", smart, session({shuffleMode:"off",sequence:"3"})), true);
assert.equal(model.commandObserved("cycleRepeat", playing, session({ repeatMode: "context", sequence: "2" })), true);
assert.equal(model.commandObserved("pause", playing, session({ sequence: "2" })), false);

// Line-timed payloads use their direct API StartTime/EndTime fields. They are
// distinct from static lyrics and receive a real active line.
const lineLyrics = model.normalizeLyrics({
  Type: "Line",
  StartTime: 5,
  Content: [
    { Type: "Vocal", Text: "First line", StartTime: 5, EndTime: 8 },
    { Type: "Vocal", Text: "Second line", StartTime: 8.2, EndTime: 12, OppositeAligned: true }
  ]
}, { durationMs: 20_000 });
assert.equal(lineLyrics.timing, "line");
assert.equal(lineLyrics.lines[0].kind, "interlude");
assert.equal(lineLyrics.lines[1].start, 5000);
assert.equal(lineLyrics.lines[1].end, 8000);
assert.equal(model.findActiveLine(lineLyrics.lines, 6500), 1);
assert.equal(model.lineVisualState(lineLyrics.lines[1], 1, 1, 6500), "active");
assert.equal(model.lineVisualState(lineLyrics.lines[1], 1, -1, 8500), "sung");

const millisecondLines = model.normalizeLyrics({
  Type: "Line",
  TimeUnit: "milliseconds",
  Content: [{ Text: "Already milliseconds", StartTime: 5000, EndTime: 8000 }]
});
assert.equal(millisecondLines.lines[1].start, 5000);

// Truly static lyrics remain readable and are never assigned fabricated time.
const staticLyrics = model.normalizeLyrics({
  Type: "Static",
  Lines: [{ Text: "Read me" }, { Text: "Without fake timing" }]
});
assert.equal(staticLyrics.timing, "static");
assert.deepEqual(staticLyrics.lines.map((line) => line.start), [null, null]);
assert.deepEqual(staticLyrics.lines.map((line) => model.lineVisualState(line, 0, -1, 99_000)), ["static", "static"]);

// Karaoke preserves the service's join-next semantics, punctuation,
// contractions, transliteration, translation, background vocals, duet
// alignment and RTL detection.
const karaoke = model.normalizeLyrics({
  Type: "Syllable",
  Content: [{
    Type: "Vocal",
    OppositeAligned: true,
    TranslatedText: "translation",
    Lead: {
      StartTime: 1,
      EndTime: 4,
      Syllables: [
        { Text: "A", IsPartOfWord: true, StartTime: 1, EndTime: 1.2 },
        { Text: "ny", StartTime: 1.2, EndTime: 1.5 },
        { Text: "time", StartTime: 1.6, EndTime: 2 },
        { Text: ",", StartTime: 2, EndTime: 2.1 },
        { Text: "don", IsPartOfWord: true, StartTime: 2.2, EndTime: 2.5 },
        { Text: "’", IsPartOfWord: true, StartTime: 2.5, EndTime: 2.55 },
        { Text: "t", StartTime: 2.55, EndTime: 2.7, TransliteratedText: "t" }
      ]
    },
    Background: [{
      StartTime: 2.3,
      EndTime: 3.2,
      Syllables: [{ Text: "مرحبا", StartTime: 2.3, EndTime: 3.2 }]
    }]
  }]
});
const lead = karaoke.lines.find((line) => line.kind === "lead");
const background = karaoke.lines.find((line) => line.kind === "background");
assert.equal(karaoke.timing, "karaoke");
assert.equal(model.textFromTokens(lead.tokens), "Any time, don’t");
assert.deepEqual(model.groupTokens(lead.tokens).map((group) => model.textFromTokens(group.tokens)), [
  "Any", "time,", "don’t"
]);
assert.equal(lead.translation, "translation");
assert.equal(lead.opposite, true);
assert.equal(background.rtl, true);
assert.equal(model.findActiveLine(karaoke.lines, 2500), karaoke.lines.indexOf(lead), "background must not steal lead scrolling");
assert.equal(model.lineVisualState(background, karaoke.lines.indexOf(background), -1, 2500), "active");
assert.equal(model.tokenProgress(lead.tokens[0], 1100), 0.5);

// Lyrics responses are generation-bound, including when a user skips away and
// immediately returns to the same track ID.
assert.equal(model.shouldAcceptLyrics(current, { trackId: "new", generation: "8" }), true);
assert.equal(model.shouldAcceptLyrics(current, { trackId: "new", generation: "7" }), false);
assert.equal(model.shouldAcceptLyrics(current, { trackId: "old", generation: "8" }), false);

// Repeated adverse transport cycles must remain deterministic with no
// cumulative pause drift or out-of-order takeover.
let accepted = null;
for (let cycle = 0; cycle < 250; cycle++) {
  const base = cycle * 10_000;
  const pauseObservation = session({
    generation: String(100 + cycle),
    sequence: "2",
    trackId: `track-${cycle}`,
    positionMs: 4250,
    isPlaying: false,
    isPaused: true,
    isAdvancing: false
  }, base + 4250);
  if (model.shouldAcceptSession(accepted, pauseObservation)) accepted = pauseObservation;
  assert.equal(model.projectedPosition(accepted, base + 9000), 4250);
  const stale = session({
    generation: String(99 + cycle),
    sequence: "9999",
    trackId: "stale",
    positionMs: 99_000
  }, base + 9500);
  assert.equal(model.shouldAcceptSession(accepted, stale), false);
  accepted = session({
    generation: String(101 + cycle),
    sequence: "1",
    trackId: `track-${cycle + 1}`,
    positionMs: 0
  }, base + 10_000);
}

// Native-to-WebKit time is measured from a same-device epoch, not guessed.
for (const age of [0, 20, 175, 350, 900]) {
  const observed = { ...playing, sampledAtEpochMs: 1_000_000, positionMs: 12_000 };
  const delivered = model.normalizeSession(observed, 5000, 1_000_000 + age);
  assert.equal(delivered.positionMs, 12_000 + age);
  assert.equal(model.projectedPosition(delivered, 5100), 12_100 + age);
  const stopped = model.normalizeSession({ ...observed, isPaused: true }, 5000, 1_000_000 + age);
  assert.equal(stopped.positionMs, 12_000, "delivery age never advances paused audio");
}
assert.equal(model.normalizeSession({ ...playing, sampledAtEpochMs: 1000 }, 10, 9000).transportExpired, true);
assert.equal(model.normalizeSession({ ...playing, sampledAtEpochMs: 1000 }, 10, 0).transportAgeMs, 0,
  "backward device clock jumps must not become negative offsets");
const flowingPreview = model.acknowledgeSeekPreview(model.beginSeekPreview(70_000, playing, 1000), true);
assert.equal(model.renderedPosition({ session: playing, now: 1400, seekPreview: flowingPreview }), 70_400,
  "accepted playing seeks keep the temporary preview moving until observed confirmation");
assert.equal(model.renderedPosition({ session: paused, now: 1400, seekPreview: flowingPreview }), 70_000);
assert.equal(model.renderedPosition({ session: playing, now: 1400, seekPreview: flowingPreview,
  lifecycleFrozen: true, frozenPositionMs: 22_000 }), 22_000, "background freeze outranks pending preview");
const captionGapLines = [
  {kind:"lead",start:1000,end:2000},
  {kind:"lead",start:4000,end:5000},
  {kind:"background",start:4000,end:5200},
  {kind:"lead",start:5800,end:7000}
];
assert.equal(model.findCaptionLine(captionGapLines, 5500), 1, "short gaps retain the current verse, not the introduction");
assert.equal(model.findCaptionLine(captionGapLines, 0), 0);
assert.equal(model.findCaptionLine(captionGapLines, 8000), 3);
assert.equal(model.findCaptionLine(captionGapLines, 6000), 3);
assert.equal(model.findCaptionLine([], 1000), -1);
assert.equal(model.findCaptionLine([{kind:"lead",text:"Untimed"}], 1000), 0);
assert.equal(model.findCaptionLine([{kind:"interlude",start:0,end:4000},...captionGapLines], 500), 0);
console.log("Spicy Lyrics renderer model tests passed");
