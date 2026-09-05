(function installSpicyLyricsModel(root, factory) {
  const model = factory();
  root.SpicyLyricsModel = model;
  if (typeof module === "object" && module.exports) module.exports = model;
})(typeof globalThis === "object" ? globalThis : this, function makeSpicyLyricsModel() {
  "use strict";

  const finite = (value, fallback = 0) => (
    Number.isFinite(Number(value)) ? Number(value) : fallback
  );
  const optionalFinite = (value) => {
    if (value == null || value === "") return null;
    const number = Number(value);
    return Number.isFinite(number) ? number : null;
  };
  const clamp = (value, minimum = 0, maximum = 1) => (
    Math.min(maximum, Math.max(minimum, finite(value, minimum)))
  );

  function compareOrdinal(left, right) {
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

  function shouldAcceptSession(current, incoming) {
    if (!incoming || !String(incoming.trackId || "")) return false;
    const incomingGeneration = String(incoming.generation || "");
    if (!incomingGeneration) return false;
    if (!current || !String(current.generation || "")) return true;
    const generationOrder = compareOrdinal(incomingGeneration, current.generation);
    if (generationOrder !== 0) return generationOrder > 0;
    if (String(incoming.trackId) !== String(current.trackId || "")) return false;
    return compareOrdinal(incoming.sequence, current.sequence) > 0;
  }

  function normalizeSession(payload, receivedAt, receivedEpochMs = null) {
    const durationMs = Math.max(0, finite(payload?.durationMs));
    const sampledAt = optionalFinite(payload?.sampledAtEpochMs);
    const epoch = optionalFinite(receivedEpochMs);
    const age = sampledAt != null && epoch != null ? epoch - sampledAt : null;
    // Both processes share the device epoch. Ignore clock jumps; never turn
    // an old/background message into seconds of invented forward progress.
    const transportAgeMs = age != null && age >= 0 && age <= 2000 ? age : 0;
    const advancing = payload?.isAdvancing && payload?.isPlaying && !payload?.isPaused
      && !payload?.isLoading && !payload?.isBuffering && !payload?.requiresFreshObservation;
    const rate = Math.max(0.01, finite(payload?.playbackRate, 1));
    const positionMs = clamp(finite(payload?.positionMs) + (advancing ? transportAgeMs * rate : 0),
      0, durationMs || Number.MAX_SAFE_INTEGER);
    const repeatMode = ["off", "context", "track"].includes(payload?.repeatMode)
      ? payload.repeatMode
      : "off";
    const isPaused = Boolean(payload?.isPaused) || !Boolean(payload?.isPlaying);
    return {
      generation: String(payload?.generation || ""),
      sequence: String(payload?.sequence || "0"),
      trackId: String(payload?.trackId || ""),
      playbackId: String(payload?.playbackId || ""),
      sessionId: String(payload?.sessionId || ""),
      positionMs,
      transportAgeMs,
      transportExpired: age != null && age > 2000,
      durationMs,
      playbackRate: Math.max(0.01, finite(payload?.playbackRate, 1)),
      isPlaying: Boolean(payload?.isPlaying),
      isPaused,
      isLoading: Boolean(payload?.isLoading),
      isBuffering: Boolean(payload?.isBuffering),
      isAdvancing: Boolean(payload?.isAdvancing)
        && !isPaused
        && !Boolean(payload?.requiresFreshObservation),
      requiresFreshObservation: Boolean(payload?.requiresFreshObservation),
      shuffleEnabled: Boolean(payload?.shuffleEnabled),
      shuffleMode: ["off", "shuffle", "smart"].includes(payload?.shuffleMode)
        ? payload.shuffleMode : (payload?.shuffleEnabled ? "shuffle" : "off"),
      smartShuffleAvailable: Boolean(payload?.smartShuffleAvailable),
      repeatMode,
      canSeek: payload?.canSeek !== false,
      canPause: payload?.canPause !== false,
      canResume: payload?.canResume !== false,
      canGoPrevious: payload?.canGoPrevious !== false,
      canGoNext: payload?.canGoNext !== false,
      canToggleShuffle: payload?.canToggleShuffle !== false,
      canToggleRepeatContext: payload?.canToggleRepeatContext !== false,
      canToggleRepeatTrack: payload?.canToggleRepeatTrack !== false,
      track: payload?.track && typeof payload.track === "object" ? payload.track : {},
      receivedAt: finite(receivedAt)
    };
  }

  function projectedPosition(session, now) {
    if (!session) return 0;
    let position = Math.max(0, finite(session.positionMs));
    if (session.isAdvancing
        && !session.requiresFreshObservation
        && !session.isLoading
        && !session.isBuffering) {
      position += Math.max(0, finite(now) - finite(session.receivedAt, now))
        * Math.max(0.01, finite(session.playbackRate, 1));
    }
    const duration = Math.max(0, finite(session.durationMs));
    return duration > 0 ? Math.min(position, duration) : position;
  }

  function beginSeekPreview(targetMs, session, now, timeoutMs = 2200) {
    const duration = Math.max(0, finite(session?.durationMs));
    return {
      targetMs: clamp(targetMs, 0, duration || Number.MAX_SAFE_INTEGER),
      generation: String(session?.generation || ""),
      baselineSequence: String(session?.sequence || "0"),
      startedAt: finite(now),
      deadlineAt: finite(now) + Math.max(500, finite(timeoutMs, 2200)),
      accepted: null
    };
  }

  function acknowledgeSeekPreview(preview, accepted) {
    return preview ? { ...preview, accepted: Boolean(accepted) } : null;
  }

  function reconcileSeekPreview(preview, session, now) {
    if (!preview || !session) return null;
    if (preview.accepted === false) return null;
    if (String(session.generation || "") !== preview.generation) return null;
    const newer = compareOrdinal(session.sequence, preview.baselineSequence) > 0;
    const tolerance = Math.min(1500, Math.max(450, finite(session.durationMs) * 0.0025));
    const predicted = previewPosition(preview, session, now);
    if (newer && Math.min(Math.abs(finite(session.positionMs) - preview.targetMs),
      Math.abs(finite(session.positionMs) - predicted)) <= tolerance) return null;
    if (finite(now) >= preview.deadlineAt) return null;
    return preview;
  }

  function previewPosition(preview, session, now) {
    const elapsed = preview.accepted === true && session?.isAdvancing
      && !session?.requiresFreshObservation ? Math.max(0, finite(now) - preview.startedAt) : 0;
    return clamp(preview.targetMs + elapsed * Math.max(.01, finite(session?.playbackRate, 1)),
      0, finite(session?.durationMs) || Number.MAX_SAFE_INTEGER);
  }

  function renderedPosition({
    session,
    now,
    lifecycleFrozen = false,
    frozenPositionMs = 0,
    dragging = false,
    dragPositionMs = 0,
    seekPreview = null
  }) {
    if (dragging) return Math.max(0, finite(dragPositionMs));
    if (lifecycleFrozen) return Math.max(0, finite(frozenPositionMs));
    if (seekPreview) return previewPosition(seekPreview, session, now);
    return projectedPosition(session, now);
  }

  function commandObserved(command, baseline, current) {
    if (!baseline || !current) return false;
    const generationChanged = String(current.generation) !== String(baseline.generation);
    const trackChanged = String(current.trackId) !== String(baseline.trackId);
    switch (command) {
    case "togglePlay":
      return current.isPaused !== baseline.isPaused;
    case "play":
      return !current.isPaused && current.isPlaying;
    case "pause":
      return current.isPaused || !current.isPlaying;
    case "next":
      return generationChanged || trackChanged;
    case "previous":
      return generationChanged
        || trackChanged
        || (finite(baseline.positionMs) > 1500
          && finite(current.positionMs) + 1000 < finite(baseline.positionMs));
    case "toggleShuffle":
      // Native Smart Shuffle may report ordinary Shuffle while disabling its
      // recommendation context. Only the requested final mode confirms it.
      return current.shuffleMode === (baseline.shuffleMode === "off" ? "shuffle"
        : baseline.shuffleMode === "shuffle" && baseline.smartShuffleAvailable ? "smart" : "off");
    case "cycleRepeat":
      return current.repeatMode !== baseline.repeatMode;
    default:
      return false;
    }
  }

  function timeScale(data) {
    const unit = String(
      data?.TimeUnit ?? data?.timeUnit ?? data?.TimingUnit ?? data?.timingUnit ?? ""
    ).trim().toLowerCase();
    if (["ms", "millisecond", "milliseconds"].includes(unit)) return 1;
    if (["us", "microsecond", "microseconds"].includes(unit)) return 0.001;
    return 1000;
  }

  const stripZeroWidth = (value) => String(value ?? "").replace(/[\u200B-\u200D\uFEFF]/g, "");
  const isRTL = (value) => /[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFC]/u.test(String(value || ""));
  const startsWithClosingPunctuation = (value) => /^[,.;:!?%…\)\]\}’”'،؛؟]/u.test(value);
  const endsWithOpeningPunctuation = (value) => /[\(\[\{“‘"¿¡]$/u.test(value);
  const isApostrophe = (value) => /^[’']$/u.test(value);

  function translationFrom(...objects) {
    const candidates = [];
    objects.filter(Boolean).forEach((object) => {
      candidates.push(
        object.TranslatedText,
        object.Translation?.Text,
        ...(Array.isArray(object.Translations)
          ? object.Translations.map((translation) => translation?.Text)
          : [])
      );
    });
    return String(candidates.find((value) => typeof value === "string" && value.trim()) || "");
  }

  function normalizeTokens(syllables, scale, parentStart, parentEnd) {
    const source = Array.isArray(syllables) ? syllables : [];
    const tokens = [];
    source.forEach((syllable, index) => {
      const text = stripZeroWidth(syllable?.Text);
      const transliterated = stripZeroWidth(syllable?.TransliteratedText);
      if (!text && !transliterated) return;
      const previousRaw = source[index - 1];
      const previousText = stripZeroWidth(previousRaw?.Text);
      const startsAt = optionalFinite(syllable?.StartTime);
      const nextStartsAt = optionalFinite(source[index + 1]?.StartTime);
      const endsAt = optionalFinite(syllable?.EndTime);
      const start = startsAt == null
        ? (index === 0 ? optionalFinite(parentStart) : null)
        : startsAt;
      if (start == null) return;
      const endCandidate = endsAt != null && endsAt > start
        ? endsAt
        : (nextStartsAt != null && nextStartsAt > start
          ? nextStartsAt
          : (index === source.length - 1 ? optionalFinite(parentEnd) : null));
      const joinsPrevious = index > 0 && (
        previousRaw?.IsPartOfWord === true
        || startsWithClosingPunctuation(text)
        || endsWithOpeningPunctuation(previousText)
        || isApostrophe(previousText)
      );
      tokens.push({
        text,
        transliterated,
        start: start * scale,
        end: (endCandidate != null && endCandidate > start ? endCandidate : start + 0.16) * scale,
        joinsPrevious,
        joinsNext: syllable?.IsPartOfWord === true
          || endsWithOpeningPunctuation(text)
          || isApostrophe(text),
        spaceBefore: index > 0 && !joinsPrevious
      });
    });
    return tokens;
  }

  function groupTokens(tokens) {
    const groups = [];
    let current = null;
    (Array.isArray(tokens) ? tokens : []).forEach((token, index, source) => {
      const joinsPrevious = Boolean(token?.joinsPrevious)
        || Boolean(source[index - 1]?.joinsNext)
        || token?.spaceBefore === false;
      if (!current || !joinsPrevious) {
        current = { tokens: [], spaceBefore: index > 0 && token?.spaceBefore !== false };
        groups.push(current);
      }
      current.tokens.push(token);
    });
    return groups;
  }

  function textFromTokens(tokens, romanized = false) {
    let result = "";
    (Array.isArray(tokens) ? tokens : []).forEach((token, index) => {
      const text = romanized && String(token.transliterated || "").trim()
        ? String(token.transliterated)
        : String(token.text || "");
      if (index > 0 && token.spaceBefore) result += " ";
      result += text;
    });
    return result;
  }

  function addInterlude(output, start, end, opposite = false) {
    if (Number.isFinite(start) && Number.isFinite(end) && end - start >= 3000) {
      output.push({ kind: "interlude", start, end, opposite });
    }
  }

  function normalizeStatic(data) {
    const source = Array.isArray(data?.Lines)
      ? data.Lines
      : (Array.isArray(data?.Content) ? data.Content : []);
    return source.map((entry) => ({
      kind: "static",
      text: stripZeroWidth(entry?.Text),
      romanizedText: stripZeroWidth(entry?.TransliteratedText),
      translation: translationFrom(entry),
      start: null,
      end: null,
      tokens: [],
      opposite: Boolean(entry?.OppositeAligned),
      rtl: isRTL(entry?.Text)
    })).filter((line) => line.text || line.romanizedText);
  }

  function normalizeLine(data, scale, durationMs) {
    const content = (Array.isArray(data?.Content) ? data.Content : []).filter((entry) => (
      !entry?.Type || String(entry.Type).toLowerCase() === "vocal"
    ));
    const output = [];
    let previousEnd = 0;
    content.forEach((entry, index) => {
      const lead = entry?.Lead || {};
      const text = stripZeroWidth(entry?.Text ?? lead.Text);
      const romanizedText = stripZeroWidth(entry?.TransliteratedText ?? lead.TransliteratedText);
      const rawStart = optionalFinite(entry?.StartTime ?? lead.StartTime);
      if (!text || rawStart == null) return;
      const rawEnd = optionalFinite(entry?.EndTime ?? lead.EndTime);
      const next = content[index + 1];
      const nextStart = optionalFinite(next?.StartTime ?? next?.Lead?.StartTime);
      const start = rawStart * scale;
      const end = rawEnd != null && rawEnd > rawStart
        ? rawEnd * scale
        : (nextStart != null && nextStart > rawStart
          ? nextStart * scale
          : Math.max(start + 1000, durationMs || start + 4200));
      addInterlude(output, previousEnd, start, Boolean(entry?.OppositeAligned));
      output.push({
        kind: "lead",
        text,
        romanizedText,
        translation: translationFrom(entry, lead),
        start,
        end,
        tokens: [],
        opposite: Boolean(entry?.OppositeAligned ?? lead?.OppositeAligned),
        rtl: isRTL(text)
      });
      previousEnd = Math.max(previousEnd, end);
    });
    return output;
  }

  function normalizeSyllable(data, scale) {
    const content = Array.isArray(data?.Content) ? data.Content : [];
    const output = [];
    let previousLeadEnd = 0;
    content.forEach((entry) => {
      if (entry?.Type && String(entry.Type).toLowerCase() !== "vocal") {
        const start = optionalFinite(entry?.StartTime);
        const end = optionalFinite(entry?.EndTime);
        if (start != null && end != null) addInterlude(output, start * scale, end * scale);
        return;
      }
      const lead = entry?.Lead || {};
      const tokens = normalizeTokens(
        lead.Syllables,
        scale,
        lead.StartTime,
        lead.EndTime
      );
      const explicitStart = optionalFinite(lead.StartTime);
      const explicitEnd = optionalFinite(lead.EndTime);
      const start = explicitStart != null ? explicitStart * scale : tokens[0]?.start;
      if (!Number.isFinite(start) || (!tokens.length && !lead.Text)) return;
      const tokenEnd = tokens[tokens.length - 1]?.end;
      const end = explicitEnd != null && explicitEnd * scale > start
        ? explicitEnd * scale
        : (Number.isFinite(tokenEnd) && tokenEnd > start ? tokenEnd : start + 250);
      const opposite = Boolean(entry?.OppositeAligned ?? lead?.OppositeAligned);
      addInterlude(output, previousLeadEnd, start, opposite);
      const text = stripZeroWidth(lead.Text) || textFromTokens(tokens, false);
      output.push({
        kind: "lead",
        text,
        romanizedText: stripZeroWidth(lead.TransliteratedText) || textFromTokens(tokens, true),
        translation: translationFrom(entry, lead),
        start,
        end,
        tokens,
        opposite,
        rtl: isRTL(text)
      });
      previousLeadEnd = Math.max(previousLeadEnd, end);

      (Array.isArray(entry?.Background) ? entry.Background : []).forEach((background) => {
        const backgroundTokens = normalizeTokens(
          background?.Syllables,
          scale,
          background?.StartTime,
          background?.EndTime
        );
        if (!backgroundTokens.length) return;
        const backgroundStart = optionalFinite(background?.StartTime);
        const backgroundEnd = optionalFinite(background?.EndTime);
        const bgStart = backgroundStart != null ? backgroundStart * scale : backgroundTokens[0].start;
        const finalTokenEnd = backgroundTokens[backgroundTokens.length - 1].end;
        const bgEnd = backgroundEnd != null && backgroundEnd * scale > bgStart
          ? backgroundEnd * scale
          : Math.max(bgStart + 160, finalTokenEnd);
        const backgroundText = textFromTokens(backgroundTokens, false);
        output.push({
          kind: "background",
          text: backgroundText,
          romanizedText: textFromTokens(backgroundTokens, true),
          translation: translationFrom(background),
          start: bgStart,
          end: bgEnd,
          tokens: backgroundTokens,
          opposite,
          rtl: isRTL(backgroundText),
          parentStart: start
        });
      });
    });
    return output;
  }

  function normalizeLyrics(data, options = {}) {
    if (!data || typeof data !== "object") {
      return { type: "unknown", timing: "none", timeScale: 1000, lines: [] };
    }
    const type = String(data.Type || "").trim().toLowerCase();
    const scale = timeScale(data);
    const durationMs = Math.max(0, finite(options.durationMs));
    let lines;
    if (type === "static") lines = normalizeStatic(data);
    else if (type === "line") lines = normalizeLine(data, scale, durationMs);
    else if (type === "syllable") lines = normalizeSyllable(data, scale);
    else lines = [];
    return {
      type: type || "unknown",
      timing: type === "syllable" ? "karaoke" : (type === "line" ? "line" : "static"),
      timeScale: scale,
      lines
    };
  }

  function findActiveLine(lines, positionMs) {
    const position = finite(positionMs);
    let activeInterlude = -1;
    for (let index = 0; index < (lines || []).length; index++) {
      const line = lines[index];
      if (line.kind === "background" || !Number.isFinite(line.start) || !Number.isFinite(line.end)) {
        continue;
      }
      if (position >= line.start && position < line.end) {
        if (line.kind === "lead") return index;
        activeInterlude = index;
      }
    }
    return activeInterlude;
  }

  function findCaptionLine(lines, positionMs, activeIndex = findActiveLine(lines, positionMs)) {
    if (activeIndex >= 0) return activeIndex;
    let previous = -1;
    let first = -1;
    (lines || []).forEach((line, index) => {
      if (line.kind === "background" || line.kind === "interlude") return;
      if (first < 0) first = index;
      if (Number.isFinite(line.start) && line.start <= positionMs
          && (previous < 0 || line.start >= lines[previous].start)) previous = index;
    });
    return previous >= 0 ? previous : first;
  }

  function lineVisualState(line, index, activeIndex, positionMs) {
    if (!Number.isFinite(line?.start) || !Number.isFinite(line?.end)) return "static";
    const position = finite(positionMs);
    if (line.kind === "background") {
      if (position >= line.start && position < line.end) return "active";
      return position >= line.end ? "sung" : "not-sung";
    }
    if (index === activeIndex) return "active";
    return position >= line.end ? "sung" : "not-sung";
  }

  function tokenProgress(token, positionMs) {
    if (!Number.isFinite(token?.start) || !Number.isFinite(token?.end)) return 0;
    return clamp((finite(positionMs) - token.start) / Math.max(1, token.end - token.start));
  }

  function shouldAcceptLyrics(session, payload) {
    return Boolean(session && payload)
      && String(payload.trackId || "") === String(session.trackId || "")
      && String(payload.generation || "") === String(session.generation || "");
  }

  return {
    finite,
    optionalFinite,
    clamp,
    compareOrdinal,
    shouldAcceptSession,
    normalizeSession,
    projectedPosition,
    beginSeekPreview,
    acknowledgeSeekPreview,
    reconcileSeekPreview,
    renderedPosition,
    commandObserved,
    timeScale,
    isRTL,
    normalizeTokens,
    groupTokens,
    textFromTokens,
    normalizeLyrics,
    findActiveLine,
    findCaptionLine,
    lineVisualState,
    tokenProgress,
    shouldAcceptLyrics
  };
});
