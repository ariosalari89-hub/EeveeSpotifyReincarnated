import Kawarp from "./Reference/kawarp-1.2.0.js";

const source = document.createElement("canvas");
source.width = 256; source.height = 256;
const ink = source.getContext("2d");
ink.fillStyle = "#090b11"; ink.fillRect(0, 0, 256, 256);
// Asymmetric source regions: reducing these to a palette destroys their layout.
ink.fillStyle = "#e32859"; ink.fillRect(0, 0, 153, 120);
ink.fillStyle = "#157ded"; ink.fillRect(157, 45, 99, 211);
ink.fillStyle = "#e0a72e"; ink.fillRect(18, 156, 127, 100);
ink.fillStyle = "#268f61"; ink.fillRect(65, 100, 90, 74);
const reference = new Kawarp(document.querySelector("#reference"), {
  warpIntensity: 1, blurPasses: 8, animationSpeed: .1, saturation: 1.5,
  dithering: .008, transitionDuration: 500, tintIntensity: 0, scale: 1
});
reference.loadImageElement(source);
reference.animationSpeed = 1;
reference.start();
const mobile = new window.SpicyGradientField(document.querySelector("#mobile"));
// Playback preferences arrive before an asynchronous artwork decode completes.
mobile.setMotion(true, 100);
if (typeof mobile.setImage === "function") mobile.setImage(source);
else mobile.setPalette([[227, 40, 89], [21, 125, 237], [224, 167, 46], [38, 143, 97]]);
mobile.setMotion(true, 100);

const sample = document.createElement("canvas");
sample.width = 300; sample.height = 150;
const context = sample.getContext("2d", { willReadFrequently: true });
function pixels(canvas) {
  context.clearRect(0, 0, 300, 150);
  context.drawImage(canvas, 0, 0, 300, 150);
  return context.getImageData(0, 0, 300, 150).data;
}
const results = [];
const times = new Set([1000, 4000, 10000, 60000]);
for (let frame = 0; frame <= 3600; frame++) {
  const elapsed = frame * 1000 / 60;
  window.advanceGradientClock(elapsed);
  if (frame === 60) reference.transitionDuration = 1000;
  if (!times.has(Math.round(elapsed))) continue;
  const expected = pixels(document.querySelector("#reference"));
  const actual = pixels(document.querySelector("#mobile canvas"));
  let total = 0, worst = 0, changed = 0;
  for (let offset = 0; offset < expected.length; offset += 4) {
    let difference = 0;
    for (let channel = 0; channel < 3; channel++) {
      const delta = Math.abs(actual[offset + channel] - expected[offset + channel]);
      total += delta; worst = Math.max(worst, delta); difference = Math.max(difference, delta);
    }
    if (difference > 1) changed++;
  }
  results.push({ milliseconds: Math.round(elapsed), meanChannelError: total / (300 * 150 * 3),
    maximumChannelError: worst, differentPixels: changed });
}
reference.stop(); mobile.setMotion(false, 100);
window.pcGradientParity = {
  pass: results.length === 4 && results.every(result => result.maximumChannelError <= 1),
  samples: results,
  mobileSize: [mobile.canvas.width, mobile.canvas.height],
  referenceSize: [300, 150]
};
document.querySelector("#result").textContent = JSON.stringify(window.pcGradientParity, null, 2);
