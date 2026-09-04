(function installSpicyLyricsModel(root, factory) {
  const model = factory();
  root.SpicyLyricsModel = model;
  if (typeof module === "object" && module.exports) module.exports = model;
})(typeof globalThis === "object" ? globalThis : this, function makeSpicyLyricsModel() {
  "use strict";

  const finite = (value, fallback = 0) => (
    Number.isFinite(Number(value)) ? Number(value) : fallback
  );

  function compareSequence(left, right) {
    try {
      const lhs = BigInt(String(left ?? "0"));
      const rhs = BigInt(String(right ?? "0"));
      return lhs === rhs ? 0 : (lhs > rhs ? 1 : -1);
    } catch (_) {
      const lhs = finite(left);
      const rhs = finite(right);
      return lhs === rhs ? 0 : (lhs > rhs ? 1 : -1);
    }
  }

  function shouldAcceptGeneration(current, incoming) {
    const currentGeneration = String(current || "");
    const incomingGeneration = String(incoming || "");
    if (!incomingGeneration) return !currentGeneration;
    if (!currentGeneration) return true;
    return compareSequence(incomingGeneration, currentGeneration) >= 0;
  }

  function shouldAcceptPlayback(current, incoming) {
    const currentGeneration = String(current?.generation || "");
    const incomingGeneration = String(incoming?.generation || "");
    if (!shouldAcceptGeneration(currentGeneration, incomingGeneration)) return false;
    if (incomingGeneration !== currentGeneration) return true;
    return compareSequence(incoming?.sequence, current?.sequence) > 0;
  }

  function interpolatedPosition({
    playback,
    now,
    clockSuspended,
    suspendedPosition,
    dragging,
    dragPosition
  }) {
    if (dragging) return finite(dragPosition);
    if (clockSuspended) return finite(suspendedPosition);
    const base = finite(playback?.positionMs);
    if (!playback?.isPlaying) return base;
    const elapsed = Math.max(0, finite(now) - finite(playback?.receivedAt, now));
    return base + elapsed * Math.max(0.1, finite(playback?.playbackRate, 1));
  }

  function groupTokens(tokens) {
    const source = Array.isArray(tokens) ? tokens : [];
    const groups = [];
    let current = null;
    source.forEach((token, index) => {
      const previous = index > 0 ? source[index - 1] : null;
      const joinsPrevious = Boolean(previous?.joinsNext);
      const attachesWithoutSpace = index > 0 && token?.spaceBefore === false;
      if (!current || (!joinsPrevious && !attachesWithoutSpace)) {
        current = { tokens: [], spaceBefore: Boolean(token?.spaceBefore) };
        groups.push(current);
      }
      current.tokens.push(token);
    });
    return groups;
  }

  function lyricLineState(line, index, activeIndex, position) {
    const start = Number(line?.start);
    const end = Number(line?.end);
    const timed = Number.isFinite(start) && Number.isFinite(end);
    if (!timed) return "static";
    const backgroundActive = line?.kind === "background"
      && position >= start
      && position <= end;
    if (index === activeIndex || backgroundActive) return "active";
    return position > end ? "sung" : "not-sung";
  }

  return {
    compareSequence,
    shouldAcceptGeneration,
    shouldAcceptPlayback,
    interpolatedPosition,
    groupTokens,
    lyricLineState
  };
});
