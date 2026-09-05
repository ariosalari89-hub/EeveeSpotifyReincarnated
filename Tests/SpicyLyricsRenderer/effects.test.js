const assert = require('node:assert/strict');
const effects = require('../../layout/Library/Application Support/EeveeSpotify.bundle/SpicyLyricsRenderer/renderer-effects.js');

// Independent values captured from the desktop reference's cubic-spline 3.0.3.
const samples = [
  ['word', .125, {scale:.9811571269132652, y:-.004532375257201652, glow:.8651620370370371}],
  ['word', .5, {scale:1.0485204081632653, y:-.03534979423868313, glow:1.2376543209876543}],
  ['word', 1, {scale:1, y:0, glow:0}],
  ['dot', .5, {scale:1.0153061224489797, y:-.27407407407407414, glow:.9097222222222223, opacity:.9413194444444445}],
  ['line', .125, {glow:.3671875}],
  ['line', .5, {glow:1}]
];
for (const [kind, progress, expected] of samples) {
  const actual=effects.targets(kind,progress);
  for(const key of Object.keys(expected)) assert.ok(Math.abs(actual[key]-expected[key])<1e-10,
    `${kind} at ${progress}: ${key} was ${actual[key]}`);
}
const target=effects.targets('word',.5);
const motion=effects.create('word');
const first=effects.step(motion,target,1/60);
assert.ok(first.scale>.95 && first.scale<target.scale, 'word springs move through intermediate scale');
let settled;
for(let i=0;i<360;i++) settled=effects.step(motion,target,1/60);
assert.equal(settled.moving,false,'paused word effects stop after settling');
assert.equal(settled.scale,target.scale);
const seek=effects.step(motion,effects.targets('word',0),0,true);
assert.equal(seek.scale,.95,'a seek can reset the visual state without stale spring momentum');
assert.equal(seek.glow,0);
console.log('Desktop effect targets, spring settling and reset checks passed');
assert.deepEqual(effects.letters('Hold',0,999,false),[],'short syllables are not emphasized');
assert.deepEqual(effects.letters('سلام',0,2250,true),[],'RTL shaping is never split');
assert.deepEqual(effects.letters('👩🏽‍🚀 e\u0301',0,2250,false).map(letter=>letter.text),['👩🏽‍🚀',' ','e\u0301']);
assert.equal(effects.letters('Hold',0,2250,false).at(-1).end,2000);
assert.equal(effects.letterTargets(2,4,.375).glow,0,'future letters do not glow early');
assert.equal(effects.letterTargets(0,4,1).scale,1,'completed emphasis returns to resting size');
console.log('Desktop emphasis eligibility, grapheme safety and timing checks passed');
