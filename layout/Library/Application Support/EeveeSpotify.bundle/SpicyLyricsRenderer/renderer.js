(() => {
  "use strict";

  const RENDERER_PROTOCOL_VERSION = 4;
  const model = window.SpicyLyricsModel;
  if (!model) throw new Error("Spicy Lyrics renderer model is missing");

  const $ = (selector) => document.querySelector(selector);
  const dom = {
    app: $("#app"),
    canvas: $("#ambient-canvas"),
    backdrop: $("#artwork-backdrop"),
    cover: $("#cover"),
    miniCover: $("#mini-cover"),
    title: $("#title"),
    artist: $("#artist"),
    album: $("#album"),
    miniTitle: $("#mini-title"),
    miniArtist: $("#mini-artist"),
    lyrics: $("#lyrics"),
    scroller: $("#lyrics-scroller"),
    lyricState: $("#lyrics-state"),
    resumeScroll: $("#resume-scroll"),
    elapsed: $("#elapsed"),
    duration: $("#duration"),
    seek: $("#seek"),
    play: $("#play-button"),
    shuffle: $("#shuffle-button"),
    previous: $("#previous-button"),
    next: $("#next-button"),
    repeat: $("#repeat-button"),
    close: $("#close-button"),
    settings: $("#settings-button"),
    settingsClose: $("#settings-close"),
    settingsSheet: $("#settings-sheet"),
    settingsScrim: $("#settings-scrim"),
    romanized: $("#romanized-toggle"),
    translations: $("#translation-toggle"),
    background: $("#background-toggle"),
    fontSize: $("#font-size"),
    fontOutput: $("#font-output"),
    playbackOffset: $("#playback-offset"),
    offsetOutput: $("#offset-output")
  };

  const storedPreferences = (() => {
    try { return JSON.parse(localStorage.getItem("spicy-ios-preferences") || "{}"); }
    catch (_) { return {}; }
  })();

  const storedPlaybackOffset = Number(storedPreferences.playbackOffset);
  const validStoredPlaybackOffset = Number.isFinite(storedPlaybackOffset)
    && Math.abs(storedPlaybackOffset) <= 5000
    ? storedPlaybackOffset
    : 0;

  const state = {
    rawLyrics: null,
    trackId: "",
    generation: "",
    lyricsTrackId: "",
    lyricsGeneration: "",
    lyricsTimeScale: 1000,
    lines: [],
    lineElements: [],
    activeLine: -1,
    followLyrics: true,
    draggingSeek: false,
    dragPosition: 0,
    clockSuspended: false,
    suspendedPositionMs: 0,
    nativeReduceMotion: false,
    playback: {
      positionMs: 0,
      durationMs: 0,
      isPlaying: false,
      playbackRate: 1,
      receivedAt: performance.now(),
      generation: "",
      sequence: "0",
      source: "unavailable",
      requiresFreshSample: true,
      shuffleEnabled: false,
      repeatMode: "off",
      shuffleAvailable: false,
      repeatAvailable: false,
      pendingSeekMs: null
    },
    preferences: {
      romanized: Boolean(storedPreferences.romanized),
      translations: storedPreferences.translations !== false,
      dynamicBackground: storedPreferences.dynamicBackground !== false,
      fontSize: Number(storedPreferences.fontSize) || 100,
      playbackOffset: validStoredPlaybackOffset
    },
    pendingCommands: new Map()
  };

  const prefersReducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  const reduceMotion = () => state.nativeReduceMotion || prefersReducedMotion.matches;
  const clamp = (value, min = 0, max = 1) => Math.min(max, Math.max(min, value));
  const finite = (value, fallback = 0) => Number.isFinite(Number(value)) ? Number(value) : fallback;
  const optionalFinite = (value) => {
    if (value == null || value === "") return null;
    const number = Number(value);
    return Number.isFinite(number) ? number : null;
  };

  function lyricTimeScale(data) {
    const declaredUnit = String(
      data?.TimeUnit
      ?? data?.timeUnit
      ?? data?.TimingUnit
      ?? data?.timingUnit
      ?? ""
    ).trim().toLowerCase();
    if (["ms", "millisecond", "milliseconds"].includes(declaredUnit)) return 1;
    if (["us", "microsecond", "microseconds"].includes(declaredUnit)) return .001;

    // This is the same contract as desktop Spicy Lyrics' ConvertTime(): every
    // API/TTML lyric timestamp is expressed in seconds and is multiplied by
    // 1000. Never infer the unit from Spotify's current duration. Track and
    // playback callbacks are independent, so doing that made identical lyrics
    // normalize differently depending on which callback happened to arrive
    // first (the reproducible failure behind songs such as No Scrubs).
    return 1000;
  }

  const toMilliseconds = (value, scale) => {
    const number = optionalFinite(value);
    return number == null ? null : number * scale;
  };

  function formatTime(milliseconds) {
    const seconds = Math.max(0, Math.floor(finite(milliseconds) / 1000));
    const minutes = Math.floor(seconds / 60);
    return `${minutes}:${String(seconds % 60).padStart(2, "0")}`;
  }

  function post(type, payload = {}, button = null, timeoutMs = 1800) {
    const requestId = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    if (button) {
      button.classList.add("pending");
      button.setAttribute("aria-busy", "true");
      const timeout = setTimeout(() => settleCommand(requestId), timeoutMs);
      state.pendingCommands.set(requestId, {
        type,
        payload,
        button,
        timeout,
        accepted: false,
        baseline: {
          generation: state.generation,
          sequence: state.playback.sequence,
          isPlaying: state.playback.isPlaying,
          shuffleEnabled: state.playback.shuffleEnabled,
          repeatMode: state.playback.repeatMode
        }
      });
    }
    const message = { type, requestId, generation: state.generation, ...payload };
    if (window.webkit?.messageHandlers?.eevee) {
      window.webkit.messageHandlers.eevee.postMessage(message);
    }
    return requestId;
  }

  function settleCommand(requestId) {
    const pending = state.pendingCommands.get(requestId);
    if (!pending) return;
    clearTimeout(pending.timeout);
    pending.button.classList.remove("pending");
    pending.button.removeAttribute("aria-busy");
    state.pendingCommands.delete(requestId);
  }

  function acknowledgeCommand(payload) {
    const pending = state.pendingCommands.get(String(payload?.requestId || ""));
    if (!pending) return;
    if (!payload?.accepted) {
      settleCommand(String(payload.requestId));
      return;
    }
    pending.accepted = true;
    // Skip verification is completed natively before this acknowledgement.
    if (pending.type === "next" || pending.type === "previous") {
      settleCommand(String(payload.requestId));
    }
  }

  function reconcileCommands() {
    state.pendingCommands.forEach((pending, requestId) => {
      if (!pending.accepted) return;
      let settled = false;
      switch (pending.type) {
      case "togglePlay":
        settled = state.playback.isPlaying !== pending.baseline.isPlaying;
        break;
      case "play":
        settled = state.playback.isPlaying;
        break;
      case "pause":
        settled = !state.playback.isPlaying;
        break;
      case "seek":
        settled = state.playback.pendingSeekMs == null
          && Math.abs(state.playback.positionMs - finite(pending.payload.positionMs)) < 1800;
        break;
      case "toggleShuffle":
        settled = state.playback.shuffleEnabled !== pending.baseline.shuffleEnabled;
        break;
      case "cycleRepeat":
        settled = state.playback.repeatMode !== pending.baseline.repeatMode;
        break;
      }
      if (settled) settleCommand(requestId);
    });
  }

  class AmbientArtwork {
    constructor(canvas) {
      this.canvas = canvas;
      this.context = canvas.getContext("2d", { alpha: false });
      this.colors = ["#233b58", "#4f244c", "#111827", "#69442d"];
      this.image = null;
      this.playing = false;
      this.enabled = true;
      this.lastFrame = 0;
      this.phase = 0;
      this.resize = this.resize.bind(this);
      this.frame = this.frame.bind(this);
      addEventListener("resize", this.resize, { passive: true });
      this.resize();
      requestAnimationFrame(this.frame);
    }

    resize() {
      const aspect = innerWidth / Math.max(1, innerHeight);
      this.canvas.width = Math.min(380, Math.max(180, Math.round(250 * aspect)));
      this.canvas.height = Math.min(300, Math.max(180, Math.round(this.canvas.width / aspect)));
      this.draw();
    }

    setEnabled(enabled) {
      this.enabled = enabled;
      this.canvas.style.opacity = enabled ? "1" : "0";
      dom.backdrop.style.opacity = enabled ? ".24" : ".42";
      this.draw();
    }

    setPlaying(playing) { this.playing = playing; }

    setArtwork(url, fallbackColor) {
      if (fallbackColor && /^#?[0-9a-f]{6}$/i.test(fallbackColor)) {
        const color = fallbackColor.startsWith("#") ? fallbackColor : `#${fallbackColor}`;
        this.colors = [color, shade(color, .55), shade(color, 1.3), "#101010"];
      }
      if (!url) { this.image = null; this.draw(); return; }
      const image = new Image();
      image.decoding = "async";
      image.onload = () => {
        this.image = image;
        this.sampleColors(image);
        this.draw();
      };
      image.onerror = () => { this.image = null; this.draw(); };
      image.src = url;
    }

    sampleColors(image) {
      try {
        const sample = document.createElement("canvas");
        sample.width = sample.height = 24;
        const context = sample.getContext("2d", { willReadFrequently: true });
        context.drawImage(image, 0, 0, 24, 24);
        const pixels = context.getImageData(0, 0, 24, 24).data;
        const candidates = [];
        for (let i = 0; i < pixels.length; i += 32) {
          const r = pixels[i], g = pixels[i + 1], b = pixels[i + 2];
          const max = Math.max(r, g, b), min = Math.min(r, g, b);
          const saturation = max - min;
          const brightness = (r + g + b) / 3;
          if (brightness > 24 && brightness < 228) candidates.push({ r, g, b, score: saturation + brightness * .16 });
        }
        candidates.sort((a, b) => b.score - a.score);
        const selected = [];
        for (const color of candidates) {
          if (selected.every((other) => Math.hypot(color.r - other.r, color.g - other.g, color.b - other.b) > 55)) selected.push(color);
          if (selected.length === 4) break;
        }
        if (selected.length >= 2) this.colors = selected.map(({ r, g, b }) => `rgb(${r},${g},${b})`);
      } catch (_) {
        // A remote cover can taint canvas; the blurred CSS artwork remains a safe fallback.
      }
    }

    frame(timestamp) {
      const frameInterval = reduceMotion() ? 1000 : 33;
      if (timestamp - this.lastFrame >= frameInterval) {
        const speed = this.playing ? 1 : .12;
        this.phase += (timestamp - this.lastFrame) * .000045 * speed;
        this.lastFrame = timestamp;
        this.draw();
      }
      requestAnimationFrame(this.frame);
    }

    draw() {
      const context = this.context;
      if (!context || !this.enabled) return;
      const width = this.canvas.width, height = this.canvas.height;
      context.globalCompositeOperation = "source-over";
      context.fillStyle = "#101010";
      context.fillRect(0, 0, width, height);

      if (this.image) {
        const imageAspect = this.image.naturalWidth / this.image.naturalHeight;
        const canvasAspect = width / height;
        let drawWidth, drawHeight;
        if (imageAspect > canvasAspect) { drawHeight = height * 1.2; drawWidth = drawHeight * imageAspect; }
        else { drawWidth = width * 1.2; drawHeight = drawWidth / imageAspect; }
        context.globalAlpha = .22;
        context.drawImage(this.image, (width - drawWidth) / 2, (height - drawHeight) / 2, drawWidth, drawHeight);
        context.globalAlpha = 1;
      }

      context.globalCompositeOperation = "screen";
      this.colors.forEach((color, index) => {
        const phase = reduceMotion() ? index * 1.7 : this.phase * (index % 2 ? -1 : 1) + index * 1.63;
        const x = width * (.5 + Math.cos(phase) * (.3 + index * .025));
        const y = height * (.5 + Math.sin(phase * 1.23) * (.34 - index * .025));
        const radius = Math.max(width, height) * (.57 + index * .05);
        const gradient = context.createRadialGradient(x, y, 0, x, y, radius);
        gradient.addColorStop(0, color);
        gradient.addColorStop(1, "rgba(0,0,0,0)");
        context.globalAlpha = .42;
        context.fillStyle = gradient;
        context.fillRect(0, 0, width, height);
      });
      context.globalCompositeOperation = "source-over";
      context.globalAlpha = 1;
      const veil = context.createLinearGradient(0, 0, 0, height);
      veil.addColorStop(0, "rgba(0,0,0,.08)");
      veil.addColorStop(1, "rgba(0,0,0,.44)");
      context.fillStyle = veil;
      context.fillRect(0, 0, width, height);
    }
  }

  function shade(hex, factor) {
    const value = hex.replace("#", "");
    const channels = [0, 2, 4].map((offset) => parseInt(value.slice(offset, offset + 2), 16));
    return `rgb(${channels.map((channel) => Math.round(clamp(channel * factor, 0, 255))).join(",")})`;
  }

  const ambient = new AmbientArtwork(dom.canvas);

  function textFromSyllables(syllables, romanized) {
    let result = "";
    (syllables || []).forEach((syllable, index) => {
      const original = String(syllable?.Text ?? "").replace(/[\u200B-\u200D\uFEFF]/g, "");
      const transliterated = String(syllable?.TransliteratedText ?? "").trim();
      const text = romanized && transliterated ? transliterated : original;
      // Spicy's flag means this syllable joins the *next* one. It is not a
      // marker saying the current syllable joins the previous one.
      const previousJoinsCurrent = index > 0 && syllables[index - 1]?.IsPartOfWord === true;
      const punctuation = /^[,.;:!?%\)\]\}\u2019\u201d]/u.test(text);
      if (index > 0 && !previousJoinsCurrent && !punctuation && !/^\s/u.test(text)) result += " ";
      result += text;
    });
    return result;
  }

  function translationFrom(entry, lead) {
    const candidates = [
      entry?.TranslatedText,
      entry?.Translation?.Text,
      lead?.TranslatedText,
      lead?.Translation?.Text,
      Array.isArray(entry?.Translations) ? entry.Translations[0]?.Text : ""
    ];
    return candidates.find((value) => typeof value === "string" && value.trim()) || "";
  }

  function normalizeTokens(syllables, timeScale, parentStart, parentEnd) {
    const source = Array.isArray(syllables) ? syllables : [];
    return source.map((syllable, index) => {
      const text = String(syllable?.Text ?? "").replace(/[\u200B-\u200D\uFEFF]/g, "");
      const transliterated = String(syllable?.TransliteratedText ?? "");
      const previousJoinsCurrent = index > 0 && source[index - 1]?.IsPartOfWord === true;
      const displayText = transliterated.trim() || text;
      const punctuation = /^[,.;:!?%\)\]\}\u2019\u201d]/u.test(displayText);
      const start = toMilliseconds(syllable?.StartTime, timeScale)
        ?? (index === 0 ? parentStart : null);
      const nextStart = toMilliseconds(source[index + 1]?.StartTime, timeScale);
      const explicitEnd = toMilliseconds(syllable?.EndTime, timeScale);
      const end = explicitEnd != null && start != null && explicitEnd > start
        ? explicitEnd
        : (nextStart != null && start != null && nextStart > start
          ? nextStart
          : (index === source.length - 1 ? parentEnd : null));
      return {
        text,
        transliterated,
        start,
        end: start != null && end != null && end > start ? end : (start != null ? start + 250 : null),
        spaceBefore: index > 0 && !previousJoinsCurrent && !punctuation && !/^\s/u.test(displayText),
        joinsNext: syllable?.IsPartOfWord === true
      };
    }).filter((token) => (token.text || token.transliterated) && Number.isFinite(token.start));
  }

  function normalizeLyrics(data) {
    if (!data || typeof data !== "object") return [];
    const type = String(data.Type || "").toLowerCase();
    const timeScale = lyricTimeScale(data);
    state.lyricsTimeScale = timeScale;
    const output = [];

    if (type === "static") {
      (data.Lines || []).forEach((line) => {
        const text = String(line?.Text ?? "").trim();
        if (text) output.push({ kind: "static", text, start: null, end: null });
      });
      return output;
    }

    const content = Array.isArray(data.Content) ? data.Content : [];
    let previousLeadEnd = 0;
    content.forEach((entry, index) => {
      if (entry?.Type && String(entry.Type).toLowerCase() !== "vocal") {
        const start = toMilliseconds(entry.StartTime, timeScale);
        const end = toMilliseconds(entry.EndTime, timeScale);
        if (start != null && end != null && end > start) output.push({ kind: "interlude", start, end });
        return;
      }

      if (type === "syllable" || Array.isArray(entry?.Lead?.Syllables)) {
        const lead = entry?.Lead || {};
        const leadStart = toMilliseconds(lead.StartTime, timeScale);
        const leadEnd = toMilliseconds(lead.EndTime, timeScale);
        const tokens = normalizeTokens(lead.Syllables, timeScale, leadStart, leadEnd);
        if (!tokens.length && !lead.Text) return;
        const start = leadStart ?? tokens[0]?.start;
        const end = leadEnd ?? tokens[tokens.length - 1]?.end;
        if (!Number.isFinite(start)) return;
        const safeEnd = Number.isFinite(end) && end > start ? end : start + 250;
        if (start - previousLeadEnd >= 4200) output.push({ kind: "interlude", start: previousLeadEnd, end: start });
        output.push({
          kind: "lead",
          start,
          end: safeEnd,
          tokens,
          text: lead.Text || textFromSyllables(lead.Syllables, false),
          romanizedText: lead.TransliteratedText || textFromSyllables(lead.Syllables, true),
          translation: translationFrom(entry, lead),
          opposite: Boolean(entry.OppositeAligned ?? lead.OppositeAligned)
        });
        previousLeadEnd = Math.max(previousLeadEnd, safeEnd);

        (entry.Background || []).forEach((background) => {
          const rawBackgroundStart = toMilliseconds(background?.StartTime, timeScale);
          const rawBackgroundEnd = toMilliseconds(background?.EndTime, timeScale);
          const backgroundTokens = normalizeTokens(
            background?.Syllables,
            timeScale,
            rawBackgroundStart,
            rawBackgroundEnd
          );
          if (!backgroundTokens.length) return;
          const backgroundStart = rawBackgroundStart ?? backgroundTokens[0]?.start;
          const backgroundEnd = rawBackgroundEnd ?? backgroundTokens[backgroundTokens.length - 1]?.end;
          if (!Number.isFinite(backgroundStart)) return;
          output.push({
            kind: "background",
            start: backgroundStart,
            end: Number.isFinite(backgroundEnd) && backgroundEnd > backgroundStart
              ? backgroundEnd
              : backgroundStart + 250,
            tokens: backgroundTokens,
            text: textFromSyllables(background.Syllables, false),
            romanizedText: textFromSyllables(background.Syllables, true),
            translation: translationFrom(background, background),
            opposite: Boolean(entry.OppositeAligned ?? lead.OppositeAligned)
          });
        });
        return;
      }

      const text = String(entry?.Text ?? entry?.Lead?.Text ?? "").trim();
      if (!text) return;
      const start = toMilliseconds(entry.StartTime ?? entry.Lead?.StartTime, timeScale);
      if (!Number.isFinite(start)) return;
      const explicitEnd = toMilliseconds(entry.EndTime ?? entry.Lead?.EndTime, timeScale);
      const nextVocal = content.slice(index + 1).find((candidate) => (
        !candidate?.Type || String(candidate.Type).toLowerCase() === "vocal"
      ));
      const nextStart = toMilliseconds(nextVocal?.StartTime ?? nextVocal?.Lead?.StartTime, timeScale);
      const end = explicitEnd != null && explicitEnd > start
        ? explicitEnd
        : (nextStart != null && nextStart > start ? nextStart : start + 4200);
      if (start - previousLeadEnd >= 4200) output.push({ kind: "interlude", start: previousLeadEnd, end: start });
      output.push({
        kind: "lead",
        start,
        end,
        // Line-synced payloads contain no word timestamps. Desktop Spicy
        // Lyrics highlights the line as a unit; a progressive wipe across one
        // synthetic token misleadingly looks like broken word timing.
        tokens: [],
        text,
        romanizedText: String(entry.TransliteratedText || text),
        translation: translationFrom(entry, entry),
        opposite: Boolean(entry.OppositeAligned)
      });
      previousLeadEnd = end;
    });

    return output.filter((line) => line.kind === "interlude" ? line.end > line.start : Boolean(line.text || line.tokens?.length));
  }

  function renderLyrics(raw, trackId = state.trackId, generation = state.generation) {
    state.rawLyrics = raw;
    state.lyricsTrackId = trackId || "";
    state.lyricsGeneration = generation || "";
    state.lines = normalizeLyrics(raw);
    state.lineElements = [];
    state.activeLine = -1;
    dom.lyrics.dataset.timing = String(raw?.Type || "unknown").toLowerCase();
    dom.lyrics.replaceChildren();

    if (!state.lines.length) {
      showLyricsState("No lyrics are available for this track.", true);
      return;
    }

    state.lines.forEach((line, index) => {
      const timed = Number.isFinite(line.start);
      const element = document.createElement(timed && line.kind !== "interlude" ? "button" : "div");
      if (element instanceof HTMLButtonElement) {
        element.type = "button";
        element.setAttribute("aria-label", `Seek to ${formatTime(line.start)}: ${line.text}`);
        element.addEventListener("click", () => {
          state.followLyrics = true;
          updateFollowButton();
          post("seek", { positionMs: line.start }, element);
        });
      }
      element.className = `lyric-line ${line.kind}`;
      if (timed && line.kind === "lead" && !line.tokens?.length) element.classList.add("line-timed");
      if (line.opposite) element.classList.add("opposite");
      if (isRTL(line.text)) element.classList.add("rtl");
      element.dataset.index = String(index);

      if (line.kind === "interlude") {
        element.setAttribute("aria-hidden", "true");
        for (let dot = 0; dot < 3; dot++) {
          const dotElement = document.createElement("span");
          dotElement.className = "dot";
          element.appendChild(dotElement);
        }
      } else if (line.tokens?.length) {
        const lineText = document.createElement("span");
        lineText.className = "line-text";
        model.groupTokens(line.tokens).forEach((group) => {
          const groupElement = document.createElement("span");
          groupElement.className = "word-group";
          if (group.spaceBefore) groupElement.classList.add("space-before");
          group.tokens.forEach((token) => {
            const tokenElement = document.createElement("span");
            tokenElement.className = "token";
            const displayText = state.preferences.romanized && token.transliterated.trim()
              ? token.transliterated
              : token.text;
            tokenElement.textContent = displayText;
            tokenElement.dataset.text = displayText;
            groupElement.appendChild(tokenElement);
            token.element = tokenElement;
          });
          lineText.appendChild(groupElement);
        });
        element.appendChild(lineText);
      } else {
        const text = document.createElement("span");
        text.className = "line-text";
        text.textContent = state.preferences.romanized && line.romanizedText ? line.romanizedText : line.text;
        element.appendChild(text);
      }

      if (state.preferences.translations && line.translation) {
        const translation = document.createElement("span");
        translation.className = "line-translation";
        translation.textContent = line.translation;
        element.appendChild(translation);
      }
      line.element = element;
      state.lineElements.push(element);
      dom.lyrics.appendChild(element);
    });

    dom.lyricState.hidden = true;
    dom.app.setAttribute("aria-busy", "false");
    const timedLines = state.lines.filter((line) => Number.isFinite(line.start));
    post("diagnostic", {
      kind: "lyricsNormalized",
      trackId: state.lyricsTrackId,
      lyricsType: String(raw?.Type || "unknown"),
      lineCount: state.lines.length,
      timedLineCount: timedLines.length,
      firstStartMs: timedLines[0]?.start ?? -1,
      lastEndMs: timedLines[timedLines.length - 1]?.end ?? -1,
      timeScale: state.lyricsTimeScale
    });
    requestAnimationFrame(() => updateLyrics(positionNow(), true));
  }

  function isRTL(text) {
    return /[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFC]/.test(text || "");
  }

  function positionNow() {
    return model.interpolatedPosition({
      playback: state.playback,
      now: performance.now(),
      clockSuspended: state.clockSuspended,
      suspendedPosition: state.suspendedPositionMs,
      dragging: state.draggingSeek,
      dragPosition: state.dragPosition
    });
  }

  function findActiveLine(position) {
    let best = -1;
    for (let index = 0; index < state.lines.length; index++) {
      const line = state.lines[index];
      if (!Number.isFinite(line.start)) continue;
      if (position >= line.start && position <= line.end) {
        if (line.kind === "lead" || line.kind === "interlude") return index;
        if (best < 0) best = index;
      } else if (position >= line.start && line.kind !== "background") {
        best = index;
      }
    }
    return best;
  }

  function updateLyrics(position, forceScroll = false) {
    if (!state.lines.length) return;
    // Match desktop Spicy Lyrics: a positive playback offset delays the lyric
    // timeline, while transport time and seek targets remain true song time.
    position -= state.preferences.playbackOffset;
    const activeIndex = findActiveLine(position);
    state.lines.forEach((line, index) => {
      const lineState = model.lyricLineState(line, index, activeIndex, position);
      const isActive = lineState === "active";
      line.element?.classList.toggle("active", isActive);
      line.element?.classList.toggle("sung", lineState === "sung");
      line.element?.classList.toggle("not-sung", lineState === "not-sung");
      if (line.element && line.kind === "lead") {
        if (isActive) line.element.setAttribute("aria-current", "true");
        else line.element.removeAttribute("aria-current");
      }
    });
    if (activeIndex !== state.activeLine) {
      state.activeLine = activeIndex;
      if (state.followLyrics && activeIndex >= 0) scrollToLine(activeIndex);
    } else if (forceScroll && activeIndex >= 0 && state.followLyrics) {
      scrollToLine(activeIndex);
    }

    const startIndex = Math.max(0, activeIndex - 4);
    const endIndex = Math.min(state.lines.length, Math.max(activeIndex + 6, 8));
    for (let index = startIndex; index < endIndex; index++) {
      const line = state.lines[index];
      if (line.kind === "interlude") {
        const dots = line.element?.children || [];
        const section = Math.max(1, (line.end - line.start) / 3);
        [...dots].forEach((dot, dotIndex) => {
          const progress = clamp((position - (line.start + dotIndex * section)) / section);
          dot.style.setProperty("--fill-number", progress.toFixed(3));
        });
      }
      (line.tokens || []).forEach((token) => {
        if (!token.element) return;
        const duration = Math.max(1, token.end - token.start);
        const progress = clamp((position - token.start) / duration);
        const pulse = progress > 0 && progress < 1 ? Math.sin(progress * Math.PI) : 0;
        token.element.style.setProperty("--fill", `${(progress * 100).toFixed(2)}%`);
        token.element.style.setProperty("--pulse", reduceMotion() ? "0" : pulse.toFixed(3));
      });
    }
  }

  function scrollToLine(index) {
    const element = state.lines[index]?.element;
    if (!element) return;
    const target = element.offsetTop - dom.scroller.clientHeight * .42 + element.offsetHeight * .5;
    dom.scroller.scrollTo({ top: Math.max(0, target), behavior: reduceMotion() ? "auto" : "smooth" });
  }

  function showLoading() {
    dom.app.setAttribute("aria-busy", "true");
    dom.lyrics.replaceChildren();
    for (const width of [72, 91, 62, 84, 54]) {
      const skeleton = document.createElement("div");
      skeleton.className = "skeleton-line";
      skeleton.style.width = `${width}%`;
      dom.lyrics.appendChild(skeleton);
    }
    dom.lyricState.hidden = false;
    dom.lyricState.replaceChildren();
    const loader = document.createElement("div");
    loader.className = "loader";
    loader.setAttribute("aria-hidden", "true");
    for (let index = 0; index < 3; index++) loader.appendChild(document.createElement("i"));
    const copy = document.createElement("p");
    copy.textContent = "Loading lyrics…";
    dom.lyricState.append(loader, copy);
  }

  function showLyricsState(message, retry) {
    dom.app.setAttribute("aria-busy", "false");
    dom.lyrics.replaceChildren();
    dom.lyricState.hidden = false;
    dom.lyricState.replaceChildren();
    const copy = document.createElement("p");
    copy.textContent = message;
    dom.lyricState.appendChild(copy);
    if (retry) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "retry-button";
      button.textContent = "Try again";
      button.addEventListener("click", () => post("retryLyrics", {}, button));
      dom.lyricState.appendChild(button);
    }
  }

  function applyTrack(track) {
    const incomingTrackId = String(track?.id || "");
    const incomingGeneration = String(track?.generation || state.generation || "");
    const changedIdentity = incomingTrackId
      && (incomingTrackId !== state.trackId
        || (incomingGeneration && incomingGeneration !== state.generation));
    if (changedIdentity) {
      state.trackId = incomingTrackId;
      state.generation = incomingGeneration;
      state.lyricsTrackId = "";
      state.lyricsGeneration = "";
      state.rawLyrics = null;
      state.lines = [];
      state.activeLine = -1;
      state.followLyrics = true;
      state.playback.positionMs = 0;
      state.playback.durationMs = finite(track?.durationMs);
      state.playback.generation = incomingGeneration;
      state.playback.sequence = "0";
      state.playback.receivedAt = performance.now();
      state.clockSuspended = true;
      state.suspendedPositionMs = 0;
      updateFollowButton();
      showLoading();
      state.pendingCommands.forEach((pending, requestId) => {
        if (pending.baseline.generation !== incomingGeneration
            || pending.type === "next"
            || pending.type === "previous") {
          settleCommand(requestId);
        }
      });
    }
    const title = track?.title || "Unknown track";
    const artist = track?.artist || "Unknown artist";
    dom.title.textContent = title;
    dom.artist.textContent = artist;
    dom.album.textContent = track?.album || "";
    dom.miniTitle.textContent = title;
    dom.miniArtist.textContent = artist;
    if (track?.artwork) {
      dom.cover.classList.remove("ready");
      dom.cover.onload = () => dom.cover.classList.add("ready");
      dom.cover.src = track.artwork;
      dom.cover.alt = `Cover art for ${title}`;
      dom.miniCover.src = track.artwork;
      dom.miniCover.alt = "";
      dom.backdrop.style.backgroundImage = `url(${JSON.stringify(track.artwork)})`;
    }
    ambient.setArtwork(track?.artwork || "", track?.dominantColor || "");
    if (track?.durationMs > 0 && state.playback.durationMs <= 0) state.playback.durationMs = track.durationMs;
  }

  function applyPlayback(playback) {
    const incomingTrackId = String(playback.trackId || "");
    const incomingGeneration = String(playback.generation || "");
    if (incomingGeneration && state.generation && incomingGeneration !== state.generation) {
      // The track envelope normally arrives first, but treating playback as a
      // generation boundary makes rapid repeated skips safe even if WebKit
      // delivers the two messages in separate run-loop turns.
      state.generation = incomingGeneration;
      state.trackId = incomingTrackId || state.trackId;
      state.lyricsTrackId = "";
      state.lyricsGeneration = "";
      state.rawLyrics = null;
      state.lines = [];
      state.activeLine = -1;
      state.followLyrics = true;
      showLoading();
    }
    if (incomingTrackId && state.trackId && incomingTrackId !== state.trackId) return;
    const incomingSequence = String(playback.sequence || "0");
    if (!model.shouldAcceptPlayback(state.playback, {
      generation: incomingGeneration,
      sequence: incomingSequence
    })) return;
    const incomingDuration = finite(playback.durationMs);
    const repeatMode = ["off", "context", "track"].includes(playback.repeatMode)
      ? playback.repeatMode
      : "off";
    state.playback = {
      positionMs: finite(playback.positionMs),
      durationMs: incomingDuration > 0 ? incomingDuration : (state.playback.durationMs || 0),
      isPlaying: Boolean(playback.isPlaying),
      playbackRate: Math.max(.1, finite(playback.playbackRate, 1)),
      receivedAt: performance.now(),
      generation: incomingGeneration,
      sequence: incomingSequence,
      source: String(playback.source || "unavailable"),
      requiresFreshSample: Boolean(playback.requiresFreshSample),
      shuffleEnabled: Boolean(playback.shuffleEnabled),
      repeatMode,
      shuffleAvailable: playback.shuffleAvailable !== false,
      repeatAvailable: playback.repeatAvailable !== false,
      pendingSeekMs: optionalFinite(playback.pendingSeekMs)
    };
    state.clockSuspended = state.playback.requiresFreshSample || document.hidden;
    state.suspendedPositionMs = state.playback.positionMs;
    dom.play.classList.toggle("is-playing", state.playback.isPlaying);
    dom.play.setAttribute("aria-label", state.playback.isPlaying ? "Pause" : "Play");
    dom.play.setAttribute("aria-pressed", String(state.playback.isPlaying));
    dom.shuffle.disabled = !state.playback.shuffleAvailable;
    dom.shuffle.classList.toggle("active", state.playback.shuffleEnabled);
    dom.shuffle.setAttribute("aria-pressed", String(state.playback.shuffleEnabled));
    dom.shuffle.setAttribute(
      "aria-label",
      state.playback.shuffleEnabled ? "Turn shuffle off" : "Turn shuffle on"
    );
    dom.repeat.disabled = !state.playback.repeatAvailable;
    dom.repeat.dataset.mode = repeatMode;
    dom.repeat.classList.toggle("active", repeatMode !== "off");
    dom.repeat.setAttribute("aria-pressed", String(repeatMode !== "off"));
    dom.repeat.setAttribute(
      "aria-label",
      repeatMode === "track"
        ? "Turn repeat off"
        : (repeatMode === "context" ? "Repeat this track" : "Repeat all")
    );
    ambient.setPlaying(state.playback.isPlaying);
    reconcileCommands();
  }

  function animationFrame() {
    const position = positionNow();
    const duration = Math.max(1, state.playback.durationMs);
    updateLyrics(position);
    if (!state.draggingSeek) {
      dom.seek.max = String(duration);
      dom.seek.value = String(clamp(position, 0, duration));
      dom.seek.style.setProperty("--seek-progress", `${clamp(position / duration) * 100}%`);
      dom.elapsed.textContent = formatTime(position);
    }
    dom.duration.textContent = formatTime(duration);
    requestAnimationFrame(animationFrame);
  }

  function savePreferences() {
    try { localStorage.setItem("spicy-ios-preferences", JSON.stringify(state.preferences)); } catch (_) {}
  }

  function applyPreferences({ rerender = false } = {}) {
    dom.romanized.checked = state.preferences.romanized;
    dom.translations.checked = state.preferences.translations;
    dom.background.checked = state.preferences.dynamicBackground;
    dom.fontSize.value = String(state.preferences.fontSize);
    dom.fontOutput.value = `${state.preferences.fontSize}%`;
    dom.playbackOffset.value = String(state.preferences.playbackOffset);
    dom.offsetOutput.value = state.preferences.playbackOffset === 0
      ? "0 ms"
      : `${state.preferences.playbackOffset > 0 ? "+" : ""}${state.preferences.playbackOffset} ms`;
    document.documentElement.style.setProperty("--lyric-scale", String(state.preferences.fontSize / 100));
    ambient.setEnabled(state.preferences.dynamicBackground && !reduceMotion());
    if (rerender && state.rawLyrics) renderLyrics(state.rawLyrics);
    savePreferences();
  }

  function setSettingsOpen(open) {
    dom.settingsSheet.hidden = !open;
    dom.settingsScrim.hidden = !open;
    dom.settings.setAttribute("aria-expanded", String(open));
    if (open) requestAnimationFrame(() => dom.settingsClose.focus());
    else dom.settings.focus();
  }

  function updateFollowButton() { dom.resumeScroll.hidden = state.followLyrics; }

  window.SpicyNative = {
    receive(event) {
      if (!event || typeof event !== "object") return;
      const payload = event.payload || {};
      switch (event.type) {
      case "bootstrap":
        state.nativeReduceMotion = Boolean(payload.reduceMotion);
        if (payload.preferences && typeof payload.preferences === "object") {
          state.preferences.romanized = Boolean(payload.preferences.romanized);
          state.preferences.translations = payload.preferences.translations !== false;
          state.preferences.dynamicBackground = payload.preferences.dynamicBackground !== false;
          state.preferences.fontSize = clamp(finite(payload.preferences.fontSize, 100), 82, 126);
        }
        document.body.classList.toggle("native-reduce-motion", state.nativeReduceMotion);
        applyPreferences();
        break;
      case "track": applyTrack(payload); break;
      case "playback": applyPlayback(payload); break;
      case "lyrics":
        if (payload.trackId && state.trackId && payload.trackId !== state.trackId) break;
        if (payload.generation && state.generation && payload.generation !== state.generation) break;
        if (payload.state === "loading") showLoading();
        else if (payload.state === "ready") {
          renderLyrics(payload.data, payload.trackId, payload.generation);
        }
        else showLyricsState(payload.message || "Lyrics are temporarily unavailable.", true);
        break;
      case "lifecycle":
        if (payload.state === "hidden") {
          state.suspendedPositionMs = positionNow();
          state.clockSuspended = true;
        } else if (payload.state === "resuming") {
          state.suspendedPositionMs = positionNow();
          state.clockSuspended = true;
        }
        break;
      case "commandResult": acknowledgeCommand(payload); break;
      }
    }
  };

  dom.close.addEventListener("click", () => post("close", {}, dom.close));
  dom.play.addEventListener("click", () => post("togglePlay", {}, dom.play));
  dom.shuffle.addEventListener("click", () => post("toggleShuffle", {}, dom.shuffle));
  dom.previous.addEventListener("click", () => post("previous", {}, dom.previous, 9000));
  dom.next.addEventListener("click", () => post("next", {}, dom.next, 9000));
  dom.repeat.addEventListener("click", () => post("cycleRepeat", {}, dom.repeat));
  dom.settings.addEventListener("click", () => setSettingsOpen(true));
  dom.settingsClose.addEventListener("click", () => setSettingsOpen(false));
  dom.settingsScrim.addEventListener("click", () => setSettingsOpen(false));
  dom.resumeScroll.addEventListener("click", () => {
    state.followLyrics = true;
    updateFollowButton();
    if (state.activeLine >= 0) scrollToLine(state.activeLine);
  });
  let scrollPointerStart = null;
  dom.scroller.addEventListener("pointerdown", (event) => {
    scrollPointerStart = { y: event.clientY, scrollTop: dom.scroller.scrollTop };
  }, { passive: true });
  dom.scroller.addEventListener("pointermove", (event) => {
    if (!scrollPointerStart || !state.followLyrics) return;
    const moved = Math.abs(event.clientY - scrollPointerStart.y) >= 8;
    const scrolled = Math.abs(dom.scroller.scrollTop - scrollPointerStart.scrollTop) >= 4;
    if (!moved && !scrolled) return;
    state.followLyrics = false;
    updateFollowButton();
  }, { passive: true });
  const clearScrollPointer = () => { scrollPointerStart = null; };
  dom.scroller.addEventListener("pointerup", clearScrollPointer, { passive: true });
  dom.scroller.addEventListener("pointercancel", clearScrollPointer, { passive: true });
  dom.scroller.addEventListener("wheel", () => {
    state.followLyrics = false;
    updateFollowButton();
  }, { passive: true });
  dom.seek.addEventListener("input", () => {
    state.draggingSeek = true;
    state.dragPosition = finite(dom.seek.value);
    const max = Math.max(1, finite(dom.seek.max, 1));
    dom.seek.style.setProperty("--seek-progress", `${clamp(state.dragPosition / max) * 100}%`);
    dom.elapsed.textContent = formatTime(state.dragPosition);
    updateLyrics(state.dragPosition);
  });
  dom.seek.addEventListener("change", () => {
    post("seek", { positionMs: state.dragPosition }, dom.seek);
    state.draggingSeek = false;
    state.followLyrics = true;
    updateFollowButton();
  });
  dom.romanized.addEventListener("change", () => {
    state.preferences.romanized = dom.romanized.checked;
    applyPreferences({ rerender: true });
    post("setPreference", { key: "romanized", value: state.preferences.romanized });
  });
  dom.translations.addEventListener("change", () => {
    state.preferences.translations = dom.translations.checked;
    applyPreferences({ rerender: true });
    post("setPreference", { key: "translations", value: state.preferences.translations });
  });
  dom.background.addEventListener("change", () => {
    state.preferences.dynamicBackground = dom.background.checked;
    applyPreferences();
    post("setPreference", { key: "dynamicBackground", value: state.preferences.dynamicBackground });
  });
  dom.fontSize.addEventListener("input", () => {
    state.preferences.fontSize = clamp(finite(dom.fontSize.value, 100), 82, 126);
    applyPreferences();
    post("setPreference", { key: "fontSize", value: state.preferences.fontSize });
  });
  dom.playbackOffset.addEventListener("input", () => {
    state.preferences.playbackOffset = clamp(finite(dom.playbackOffset.value), -5000, 5000);
    applyPreferences();
    updateLyrics(positionNow(), true);
  });
  addEventListener("keydown", (event) => { if (event.key === "Escape") setSettingsOpen(false); });
  let resizeFollowFrame = 0;
  addEventListener("resize", () => {
    cancelAnimationFrame(resizeFollowFrame);
    resizeFollowFrame = requestAnimationFrame(() => updateLyrics(positionNow(), true));
  }, { passive: true });
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
      state.suspendedPositionMs = positionNow();
      state.clockSuspended = true;
    } else {
      state.suspendedPositionMs = positionNow();
      state.clockSuspended = true;
      post("resync");
    }
  }, { passive: true });
  prefersReducedMotion.addEventListener?.("change", () => applyPreferences());

  applyPreferences();
  showLoading();
  requestAnimationFrame(animationFrame);
  post("ready", { rendererProtocolVersion: RENDERER_PROTOCOL_VERSION });
})();
