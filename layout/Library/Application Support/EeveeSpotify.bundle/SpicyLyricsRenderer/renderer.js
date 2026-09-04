(() => {
  "use strict";

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
    previous: $("#previous-button"),
    next: $("#next-button"),
    close: $("#close-button"),
    settings: $("#settings-button"),
    settingsClose: $("#settings-close"),
    settingsSheet: $("#settings-sheet"),
    settingsScrim: $("#settings-scrim"),
    romanized: $("#romanized-toggle"),
    translations: $("#translation-toggle"),
    background: $("#background-toggle"),
    fontSize: $("#font-size"),
    fontOutput: $("#font-output")
  };

  const storedPreferences = (() => {
    try { return JSON.parse(localStorage.getItem("spicy-ios-preferences") || "{}"); }
    catch (_) { return {}; }
  })();

  const state = {
    rawLyrics: null,
    lines: [],
    lineElements: [],
    activeLine: -1,
    followLyrics: true,
    draggingSeek: false,
    dragPosition: 0,
    nativeReduceMotion: false,
    playback: {
      positionMs: 0,
      durationMs: 0,
      isPlaying: false,
      playbackRate: 1,
      receivedAt: performance.now(),
      sequence: "0"
    },
    preferences: {
      romanized: Boolean(storedPreferences.romanized),
      translations: storedPreferences.translations !== false,
      dynamicBackground: storedPreferences.dynamicBackground !== false,
      fontSize: Number(storedPreferences.fontSize) || 100
    },
    pendingCommands: new Map()
  };

  const prefersReducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  const reduceMotion = () => state.nativeReduceMotion || prefersReducedMotion.matches;
  const clamp = (value, min = 0, max = 1) => Math.min(max, Math.max(min, value));
  const finite = (value, fallback = 0) => Number.isFinite(Number(value)) ? Number(value) : fallback;
  const toMilliseconds = (value) => {
    const number = finite(value, 0);
    return Math.abs(number) > 10000 ? number : number * 1000;
  };

  function formatTime(milliseconds) {
    const seconds = Math.max(0, Math.floor(finite(milliseconds) / 1000));
    const minutes = Math.floor(seconds / 60);
    return `${minutes}:${String(seconds % 60).padStart(2, "0")}`;
  }

  function post(type, payload = {}, button = null) {
    const requestId = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    if (button) {
      button.classList.add("pending");
      button.setAttribute("aria-busy", "true");
      const timeout = setTimeout(() => settleCommand(requestId), 1800);
      state.pendingCommands.set(requestId, { button, timeout });
    }
    const message = { type, requestId, ...payload };
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
      if (index > 0 && !syllable?.IsPartOfWord) result += " ";
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

  function normalizeTokens(syllables) {
    return (syllables || []).map((syllable, index) => ({
      text: String(syllable?.Text ?? "").replace(/[\u200B-\u200D\uFEFF]/g, ""),
      transliterated: String(syllable?.TransliteratedText ?? ""),
      start: toMilliseconds(syllable?.StartTime),
      end: toMilliseconds(syllable?.EndTime),
      spaceBefore: index > 0 && !syllable?.IsPartOfWord
    })).filter((token) => token.text || token.transliterated);
  }

  function normalizeLyrics(data) {
    if (!data || typeof data !== "object") return [];
    const type = String(data.Type || "");
    const output = [];

    if (type === "Static") {
      (data.Lines || []).forEach((line) => {
        const text = String(line?.Text ?? "").trim();
        if (text) output.push({ kind: "static", text, start: null, end: null });
      });
      return output;
    }

    const content = Array.isArray(data.Content) ? data.Content : [];
    let previousLeadEnd = 0;
    content.forEach((entry, index) => {
      if (entry?.Type && entry.Type !== "Vocal") {
        const start = toMilliseconds(entry.StartTime);
        const end = toMilliseconds(entry.EndTime);
        if (end > start) output.push({ kind: "interlude", start, end });
        return;
      }

      if (type === "Syllable" || entry?.Lead?.Syllables) {
        const lead = entry?.Lead || {};
        const tokens = normalizeTokens(lead.Syllables);
        if (!tokens.length && !lead.Text) return;
        const start = lead.StartTime != null
          ? toMilliseconds(lead.StartTime)
          : finite(tokens[0]?.start);
        const end = lead.EndTime != null
          ? toMilliseconds(lead.EndTime)
          : finite(tokens[tokens.length - 1]?.end);
        if (start - previousLeadEnd >= 4200) output.push({ kind: "interlude", start: previousLeadEnd, end: start });
        output.push({
          kind: "lead",
          start,
          end: Math.max(end, start + 250),
          tokens,
          text: lead.Text || textFromSyllables(lead.Syllables, false),
          romanizedText: lead.TransliteratedText || textFromSyllables(lead.Syllables, true),
          translation: translationFrom(entry, lead),
          opposite: Boolean(entry.OppositeAligned ?? lead.OppositeAligned)
        });
        previousLeadEnd = Math.max(previousLeadEnd, end);

        (entry.Background || []).forEach((background) => {
          const backgroundTokens = normalizeTokens(background?.Syllables);
          if (!backgroundTokens.length) return;
          const backgroundStart = background.StartTime != null
            ? toMilliseconds(background.StartTime)
            : finite(backgroundTokens[0]?.start);
          const backgroundEnd = background.EndTime != null
            ? toMilliseconds(background.EndTime)
            : finite(backgroundTokens[backgroundTokens.length - 1]?.end);
          output.push({
            kind: "background",
            start: backgroundStart,
            end: Math.max(backgroundEnd, backgroundStart + 250),
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
      const start = toMilliseconds(entry.StartTime ?? entry.Lead?.StartTime);
      const explicitEnd = toMilliseconds(entry.EndTime ?? entry.Lead?.EndTime);
      const nextStart = toMilliseconds(content[index + 1]?.StartTime ?? content[index + 1]?.Lead?.StartTime);
      const end = explicitEnd > start ? explicitEnd : (nextStart > start ? nextStart : start + 4200);
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

  function renderLyrics(raw) {
    state.rawLyrics = raw;
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
        line.tokens.forEach((token) => {
          const tokenElement = document.createElement("span");
          tokenElement.className = "token";
          if (token.spaceBefore) tokenElement.classList.add("space-before");
          const displayText = state.preferences.romanized && token.transliterated.trim()
            ? token.transliterated
            : token.text;
          tokenElement.textContent = displayText;
          tokenElement.dataset.text = displayText;
          lineText.appendChild(tokenElement);
          token.element = tokenElement;
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
    requestAnimationFrame(() => updateLyrics(positionNow(), true));
  }

  function isRTL(text) {
    return /[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFC]/.test(text || "");
  }

  function positionNow() {
    if (state.draggingSeek) return state.dragPosition;
    const base = state.playback.positionMs;
    if (!state.playback.isPlaying) return base;
    return base + (performance.now() - state.playback.receivedAt) * state.playback.playbackRate;
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
    const activeIndex = findActiveLine(position);
    state.lines.forEach((line, index) => {
      const isBackgroundActive = line.kind === "background" && position >= line.start && position <= line.end;
      line.element?.classList.toggle("active", index === activeIndex || isBackgroundActive);
      line.element?.classList.toggle("past", Number.isFinite(line.end) && position > line.end);
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
    const incomingDuration = finite(playback.durationMs);
    state.playback = {
      positionMs: finite(playback.positionMs),
      durationMs: incomingDuration > 0 ? incomingDuration : (state.playback.durationMs || 0),
      isPlaying: Boolean(playback.isPlaying),
      playbackRate: Math.max(.1, finite(playback.playbackRate, 1)),
      receivedAt: performance.now(),
      sequence: String(playback.sequence || "0")
    };
    dom.play.classList.toggle("is-playing", state.playback.isPlaying);
    dom.play.setAttribute("aria-label", state.playback.isPlaying ? "Pause" : "Play");
    ambient.setPlaying(state.playback.isPlaying);
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
        if (payload.state === "loading") showLoading();
        else if (payload.state === "ready") renderLyrics(payload.data);
        else showLyricsState(payload.message || "Lyrics are temporarily unavailable.", true);
        break;
      case "commandResult": settleCommand(payload.requestId); break;
      }
    }
  };

  dom.close.addEventListener("click", () => post("close", {}, dom.close));
  dom.play.addEventListener("click", () => post("togglePlay", {}, dom.play));
  dom.previous.addEventListener("click", () => post("previous", {}, dom.previous));
  dom.next.addEventListener("click", () => post("next", {}, dom.next));
  dom.settings.addEventListener("click", () => setSettingsOpen(true));
  dom.settingsClose.addEventListener("click", () => setSettingsOpen(false));
  dom.settingsScrim.addEventListener("click", () => setSettingsOpen(false));
  dom.resumeScroll.addEventListener("click", () => {
    state.followLyrics = true;
    updateFollowButton();
    if (state.activeLine >= 0) scrollToLine(state.activeLine);
  });
  dom.scroller.addEventListener("pointerdown", () => {
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
    state.playback.positionMs = state.dragPosition;
    state.playback.receivedAt = performance.now();
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
  addEventListener("keydown", (event) => { if (event.key === "Escape") setSettingsOpen(false); });
  let resizeFollowFrame = 0;
  addEventListener("resize", () => {
    cancelAnimationFrame(resizeFollowFrame);
    resizeFollowFrame = requestAnimationFrame(() => updateLyrics(positionNow(), true));
  }, { passive: true });
  prefersReducedMotion.addEventListener?.("change", () => applyPreferences());

  applyPreferences();
  showLoading();
  requestAnimationFrame(animationFrame);
  post("ready");
})();
