"use strict";

const assert = require("node:assert/strict");
const path = require("node:path");
const model = require(path.resolve(
  __dirname,
  "../../layout/Library/Application Support/EeveeSpotify.bundle/SpicyLyricsRenderer/renderer-model.js"
));

assert.equal(model.compareSequence("90071992547409930", "90071992547409929"), 1);
assert.equal(model.shouldAcceptGeneration("8", "7"), false, "an older track generation must be rejected");
assert.equal(model.shouldAcceptGeneration("8", "8"), true, "the current track generation must be accepted");
assert.equal(model.shouldAcceptGeneration("8", "9"), true, "a newer track generation must be accepted");
assert.equal(
  model.shouldAcceptPlayback(
    { generation: "7", sequence: "12" },
    { generation: "7", sequence: "11" }
  ),
  false,
  "an older sequence in the current generation must be rejected"
);
assert.equal(
  model.shouldAcceptPlayback(
    { generation: "8", sequence: "2" },
    { generation: "7", sequence: "999" }
  ),
  false,
  "a late playback message from the previous song must never rewind the renderer"
);
assert.equal(
  model.shouldAcceptPlayback(
    { generation: "7", sequence: "99" },
    { generation: "8", sequence: "1" }
  ),
  true,
  "a new track generation must replace every prior sequence"
);

const playing = {
  positionMs: 10_000,
  isPlaying: true,
  playbackRate: 1,
  receivedAt: 500
};
assert.equal(model.interpolatedPosition({
  playback: playing,
  now: 1_250,
  clockSuspended: false,
  suspendedPosition: 0,
  dragging: false,
  dragPosition: 0
}), 10_750);
assert.equal(model.interpolatedPosition({
  playback: { ...playing, isPlaying: false },
  now: 9_000,
  clockSuspended: false,
  suspendedPosition: 0,
  dragging: false,
  dragPosition: 0
}), 10_000, "paused playback must remain frozen");
assert.equal(model.interpolatedPosition({
  playback: playing,
  now: 9_000,
  clockSuspended: true,
  suspendedPosition: 10_425,
  dragging: false,
  dragPosition: 0
}), 10_425, "backgrounded playback must use its frozen position");
assert.equal(model.interpolatedPosition({
  playback: playing,
  now: 9_000,
  clockSuspended: false,
  suspendedPosition: 0,
  dragging: true,
  dragPosition: 72_000
}), 72_000, "seek dragging must preview the requested position");

const grouped = model.groupTokens([
  { text: "com", joinsNext: true, spaceBefore: false },
  { text: "plete", joinsNext: false, spaceBefore: false },
  { text: ",", joinsNext: false, spaceBefore: false },
  { text: "again", joinsNext: false, spaceBefore: true }
]);
assert.equal(grouped.length, 2);
assert.deepEqual(grouped.map((group) => group.tokens.map((token) => token.text)), [
  ["com", "plete", ","],
  ["again"]
]);
assert.equal(grouped[1].spaceBefore, true);

const line = { kind: "lead", start: 1_000, end: 2_000 };
assert.equal(model.lyricLineState(line, 0, -1, 500), "not-sung");
assert.equal(model.lyricLineState(line, 0, 0, 1_500), "active");
assert.equal(model.lyricLineState(line, 0, -1, 2_500), "sung");
assert.equal(model.lyricLineState({ kind: "static" }, 0, -1, 50_000), "static");

console.log("Spicy Lyrics renderer model tests passed");
