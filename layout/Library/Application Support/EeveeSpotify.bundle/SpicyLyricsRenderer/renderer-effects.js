/* Desktop Spicy Lyrics default animation parameters, independently evaluated.
 * Reference: Spikerko/spicy-lyrics @ 4576d022, LyricsAnimator.ts.
 * Natural cubic interpolation and the closed-form damped oscillator keep the
 * same targets at any refresh rate, without dependencies or an extra clock.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.SpicyLyricsEffects = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  function spline(points) {
    const n = points.length;
    const second = Array(n).fill(0), upper = Array(n).fill(0), rhs = Array(n).fill(0);
    for (let i = 1; i < n - 1; i++) {
      const a = points[i][0] - points[i - 1][0];
      const b = points[i + 1][0] - points[i][0];
      const diagonal = 2 * (a + b) - a * upper[i - 1];
      upper[i] = b / diagonal;
      rhs[i] = (6 * ((points[i + 1][1] - points[i][1]) / b
        - (points[i][1] - points[i - 1][1]) / a) - a * rhs[i - 1]) / diagonal;
    }
    for (let i = n - 2; i > 0; i--) second[i] = rhs[i] - upper[i] * second[i + 1];
    return progress => {
      const p = Math.max(0, Math.min(1, Number(progress) || 0));
      let i = 0;
      while (i < n - 2 && p > points[i + 1][0]) i++;
      const width = points[i + 1][0] - points[i][0];
      const a = (points[i + 1][0] - p) / width, b = 1 - a;
      return a * points[i][1] + b * points[i + 1][1]
        + ((a * a * a - a) * second[i] + (b * b * b - b) * second[i + 1]) * width * width / 6;
    };
  }

  const glow = spline([[0, 0], [.15, 1], [.6, 1], [1, 0]]);
  const curves = {
    word: { scale: spline([[0, .95], [.7, 1.0505], [1, 1]]),
      y: spline([[0, .01], [.9, -1 / 60], [1, 0]]), glow },
    letter: { scale: spline([[0, .95], [.7, 1.175], [1, 1]]),
      y: spline([[0, .01], [.9, -1 / 56], [1, 0]]), glow },
    dot: { scale: spline([[0, .75], [.7, 1.05], [1, 1]]),
      y: spline([[0, 0], [.9, -.12], [1, 0]]),
      glow: spline([[0, 0], [.6, 1], [1, 1]]),
      opacity: spline([[0, .35], [.6, 1], [1, 1]]) },
    line: { glow: spline([[0, 0], [.5, 1], [1, 0]]) }
  };
  const springs = {
    word: { scale: [.88, .64], y: [1.45, .4], glow: [1.18, .56] },
    letter: { scale: [.88, .64], y: [1.45, .4], glow: [1.18, .56] },
    dot: { scale: [.7, .6], y: [1.25, .4], glow: [1, .5], opacity: [1, .5] },
    line: { glow: [1, .5] }
  };

  function targets(kind, progress) {
    return Object.fromEntries(Object.entries(curves[kind]).map(([key, sample]) => [key, sample(progress)]));
  }

  function create(kind) {
    return { kind, channels: Object.fromEntries(Object.entries(targets(kind, 0))
      .map(([key, position]) => [key, { position, velocity: 0 }])) };
  }

  function letters(text, start, end, rtl) {
    // Preserve Arabic/Hebrew shaping and complete emoji/combining clusters.
    // Older engines without grapheme segmentation retain the ordinary sweep.
    if (rtl || end - start < 1000 || !text.trim() || typeof Intl.Segmenter !== "function") return [];
    const segments = [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text)];
    const duration = (end - start - 250) / segments.length;
    return segments.map((segment, index) => ({ text: segment.segment,
      start: start + index * duration, end: start + (index + 1) * duration }));
  }

  function letterTargets(index, count, wordProgress) {
    if (wordProgress >= 1) return { ...targets("letter", 1), gradient: 100 };
    const active = Math.floor(wordProgress * count), progress = wordProgress * count - active;
    const resting = targets("letter", 0);
    if (wordProgress < 0 || index > active) return { ...resting, gradient: -20 };
    const base = targets("letter", progress), distance = Math.abs(index - active);
    const falloff = 1 / (1 + Math.pow(distance, 2.8));
    return {
      scale: resting.scale + (base.scale - resting.scale) * falloff,
      y: resting.y + (base.y - resting.y) * falloff,
      glow: base.glow / (1 + distance * .9),
      gradient: index < active ? 100 : -20 + 120 * Math.sin(progress * Math.PI / 2)
    };
  }

  function step(motion, target, dt, snap = false) {
    const result = { moving: false };
    for (const [key, channel] of Object.entries(motion.channels)) {
      const goal = target[key];
      if (snap) { channel.position = goal; channel.velocity = 0; }
      else {
        const [frequency, damping] = springs[motion.kind][key];
        const omega = 2 * Math.PI * frequency, damped = omega * Math.sqrt(1 - damping * damping);
        const decay = Math.exp(-damping * omega * dt);
        const cosine = Math.cos(damped * dt), sine = Math.sin(damped * dt);
        const offset = channel.position - goal, velocity = channel.velocity;
        channel.position = goal + decay * (offset * cosine
          + (velocity + damping * omega * offset) * sine / damped);
        channel.velocity = decay * (velocity * cosine
          - (damping * omega * velocity + omega * omega * offset) * sine / damped);
        if (Math.abs(channel.position - goal) <= 1 / 3840 && Math.abs(channel.velocity) <= .01) {
          channel.position = goal;
          channel.velocity = 0;
        } else result.moving = true;
      }
      result[key] = channel.position;
    }
    return result;
  }

  return { targets, create, step, letters, letterTargets };
});
