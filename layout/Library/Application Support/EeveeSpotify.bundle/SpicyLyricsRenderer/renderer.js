(() => {
  "use strict";

  const RENDERER_PROTOCOL_VERSION = 5;
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
  const storedOffset = model.finite(storedPreferences.playbackOffset);

  const state = {
    session: null,
    rawLyrics: null,
    lyricsTrackId: "",
    lyricsGeneration: "",
    lyricsType: "unknown",
    lines: [],
    activeLine: -1,
    followLyrics: true,
    draggingSeek: false,
    dragPositionMs: 0,
    seekPreview: null,
    lifecyclePhase: "visible",
    lifecycleFrozen: true,
    frozenPositionMs: 0,
    nativeReduceMotion: false,
    surface: ["card", "inline"].includes(window.SpicySurface) ? window.SpicySurface : "fullscreen",
    awaitingTransportResync: false,
    pendingCommands: new Map(),
    preferences: {
      romanized: Boolean(storedPreferences.romanized),
      translations: storedPreferences.translations !== false,
      dynamicBackground: storedPreferences.dynamicBackground !== false,
      fontSize: model.clamp(model.finite(storedPreferences.fontSize, 100), 82, 126),
      playbackOffset: model.clamp(storedOffset, -5000, 5000)
    }
  };

  const prefersReducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  document.documentElement.dataset.surface = state.surface;
  const reduceMotion = () => state.nativeReduceMotion || prefersReducedMotion.matches;

  function formatTime(milliseconds) {
    const seconds = Math.max(0, Math.floor(model.finite(milliseconds) / 1000));
    return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
  }

  function makeRequestId() {
    return `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  }

  function post(type, payload = {}, button = null, timeoutMs = 3000) {
    if (button && type !== "seek" && [...state.pendingCommands.values()].some(
      (pending) => pending.button === button
    )) return "";
    const requestId = makeRequestId();
    const generation = String(state.session?.generation || "");
    if (button) {
      button.classList.add("pending");
      button.setAttribute("aria-busy", "true");
      const timeout = setTimeout(() => settleCommand(requestId), timeoutMs);
      state.pendingCommands.set(requestId, {
        type,
        button,
        timeout,
        accepted: null,
        baseline: state.session ? { ...state.session } : null
      });
    }
    window.webkit?.messageHandlers?.eevee?.postMessage({
      type,
      requestId,
      generation,
      ...payload
    });
    return requestId;
  }

  function settleCommand(requestId) {
    const pending = state.pendingCommands.get(requestId);
    if (!pending) return;
    clearTimeout(pending.timeout);
    state.pendingCommands.delete(requestId);
    const buttonStillPending = pending.button && [...state.pendingCommands.values()].some(
      (command) => command.button === pending.button
    );
    if (!buttonStillPending) {
      pending.button?.classList.remove("pending");
      pending.button?.removeAttribute("aria-busy");
    }
  }

  function acknowledgeCommand(payload) {
    const requestId = String(payload?.requestId || "");
    const pending = state.pendingCommands.get(requestId);
    if (!pending) return;
    pending.accepted = Boolean(payload?.accepted);
    if (pending.type === "seek" && state.seekPreview?.requestId === requestId) {
      state.seekPreview = model.acknowledgeSeekPreview(
        state.seekPreview,
        pending.accepted
      );
    }
    if (!pending.accepted
        || ["close", "retryLyrics", "setPreference", "resync"].includes(pending.type)) {
      settleCommand(requestId);
    }
  }

  function reconcileCommands() {
    state.pendingCommands.forEach((pending, requestId) => {
      if (pending.accepted !== true) return;
      if (pending.type === "seek") {
        if (!state.seekPreview || state.seekPreview.requestId !== requestId) {
          settleCommand(requestId);
        }
        return;
      }
      if (model.commandObserved(pending.type, pending.baseline, state.session)) {
        settleCommand(requestId);
      }
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
      this.artworkRequest = 0;
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
      const request = ++this.artworkRequest;
      if (fallbackColor && /^#?[0-9a-f]{6}$/i.test(fallbackColor)) {
        const color = fallbackColor.startsWith("#") ? fallbackColor : `#${fallbackColor}`;
        this.colors = [color, shade(color, .55), shade(color, 1.3), "#101010"];
      }
      if (!url) { this.image = null; this.draw(); return; }
      const image = new Image();
      image.decoding = "async";
      image.onload = () => {
        if (request !== this.artworkRequest) return;
        this.image = image;
        this.sampleColors(image);
        this.draw();
      };
      image.onerror = () => {
        if (request !== this.artworkRequest) return;
        this.image = null;
        this.draw();
      };
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
        for (let index = 0; index < pixels.length; index += 32) {
          const r = pixels[index], g = pixels[index + 1], b = pixels[index + 2];
          const maximum = Math.max(r, g, b), minimum = Math.min(r, g, b);
          const brightness = (r + g + b) / 3;
          if (brightness > 24 && brightness < 228) {
            candidates.push({ r, g, b, score: maximum - minimum + brightness * .16 });
          }
        }
        candidates.sort((left, right) => right.score - left.score);
        const selected = [];
        for (const color of candidates) {
          if (selected.every((other) => Math.hypot(
            color.r - other.r,
            color.g - other.g,
            color.b - other.b
          ) > 55)) selected.push(color);
          if (selected.length === 4) break;
        }
        if (selected.length >= 2) {
          this.colors = selected.map(({ r, g, b }) => `rgb(${r},${g},${b})`);
        }
      } catch (_) {
        // Remote artwork can taint canvas. The CSS artwork remains available.
      }
    }

    frame(timestamp) {
      const frameInterval = reduceMotion() ? 1000 : 33;
      if (timestamp - this.lastFrame >= frameInterval) {
        this.phase += (timestamp - this.lastFrame) * .000045 * (this.playing ? 1 : .12);
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
        if (imageAspect > canvasAspect) {
          drawHeight = height * 1.2;
          drawWidth = drawHeight * imageAspect;
        } else {
          drawWidth = width * 1.2;
          drawHeight = drawWidth / imageAspect;
        }
        context.globalAlpha = .22;
        context.drawImage(
          this.image,
          (width - drawWidth) / 2,
          (height - drawHeight) / 2,
          drawWidth,
          drawHeight
        );
        context.globalAlpha = 1;
      }
      context.globalCompositeOperation = "screen";
      this.colors.forEach((color, index) => {
        const phase = reduceMotion()
          ? index * 1.7
          : this.phase * (index % 2 ? -1 : 1) + index * 1.63;
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
    return `rgb(${channels.map((channel) => Math.round(model.clamp(channel * factor, 0, 255))).join(",")})`;
  }

  const ambient = new AmbientArtwork(dom.canvas);

  function positionNow(now = performance.now()) {
    state.seekPreview = model.reconcileSeekPreview(state.seekPreview, state.session, now);
    return model.renderedPosition({
      session: state.session,
      now,
      lifecycleFrozen: state.lifecycleFrozen,
      frozenPositionMs: state.frozenPositionMs,
      dragging: state.draggingSeek,
      dragPositionMs: state.dragPositionMs,
      seekPreview: state.seekPreview
    });
  }

  function startSeek(targetMs, button) {
    if (!state.session?.canSeek) return;
    [...state.pendingCommands.entries()].forEach(([requestId, pending]) => {
      if (pending.type === "seek") settleCommand(requestId);
    });
    const target = model.clamp(targetMs, 0, state.session.durationMs || Number.MAX_SAFE_INTEGER);
    state.seekPreview = model.beginSeekPreview(target, state.session, performance.now());
    state.followLyrics = true;
    updateFollowButton();
    updateLyrics(target, true);
    const requestId = post("seek", { positionMs: target }, button, 3500);
    state.seekPreview.requestId = requestId;
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
    const title = String(track?.title || "Unknown track");
    const artist = String(track?.artist || "Unknown artist");
    const album = String(track?.album || "");
    dom.title.textContent = title;
    dom.artist.textContent = artist;
    dom.album.textContent = album;
    dom.miniTitle.textContent = title;
    dom.miniArtist.textContent = artist;
    const artwork = String(track?.artwork || "");
    if (artwork) {
      if (dom.cover.src !== artwork) {
        dom.cover.classList.remove("ready");
        dom.cover.onload = () => {
          if (dom.cover.getAttribute("src") === artwork) {
            dom.cover.classList.add("ready");
          }
        };
        dom.cover.onerror = () => {
          if (dom.cover.getAttribute("src") === artwork) {
            dom.cover.classList.remove("ready");
          }
        };
        dom.cover.src = artwork;
      }
      dom.cover.alt = `Cover art for ${title}`;
      dom.miniCover.src = artwork;
      dom.miniCover.alt = "";
      dom.backdrop.style.backgroundImage = `url(${JSON.stringify(artwork)})`;
    } else {
      dom.cover.removeAttribute("src");
      dom.miniCover.removeAttribute("src");
      dom.backdrop.style.backgroundImage = "none";
    }
    if (state.surface === "fullscreen") ambient.setArtwork(artwork, String(track?.dominantColor || ""));
  }

  function applyControls() {
    const session = state.session;
    if (!session) return;
    const isPlaying = session.isPlaying && !session.isPaused;
    dom.play.classList.toggle("is-playing", isPlaying);
    dom.play.setAttribute("aria-label", isPlaying ? "Pause" : "Play");
    dom.play.setAttribute("aria-pressed", String(isPlaying));
    dom.play.disabled = isPlaying ? !session.canPause : !session.canResume;
    dom.previous.disabled = !session.canGoPrevious;
    dom.next.disabled = !session.canGoNext;
    dom.shuffle.disabled = !session.canToggleShuffle;
    dom.shuffle.dataset.mode = session.shuffleMode;
    dom.shuffle.classList.toggle("active", session.shuffleMode !== "off");
    dom.shuffle.setAttribute("aria-pressed", String(session.shuffleMode !== "off"));
    dom.shuffle.setAttribute(
      "aria-label",
      session.shuffleMode === "smart" ? "Smart Shuffle on. Change shuffle mode"
        : (session.shuffleMode === "shuffle"
          ? (session.smartShuffleAvailable ? "Shuffle on. Change shuffle mode" : "Turn shuffle off")
          : "Turn shuffle on")
    );
    const repeatAvailable = session.repeatMode === "off"
      ? session.canToggleRepeatContext
      : (session.repeatMode === "context"
        ? session.canToggleRepeatTrack || session.canToggleRepeatContext
        : session.canToggleRepeatTrack);
    dom.repeat.disabled = !repeatAvailable;
    dom.repeat.dataset.mode = session.repeatMode;
    dom.repeat.classList.toggle("active", session.repeatMode !== "off");
    dom.repeat.setAttribute("aria-pressed", String(session.repeatMode !== "off"));
    dom.repeat.setAttribute(
      "aria-label",
      session.repeatMode === "track"
        ? (session.canToggleRepeatContext ? "Turn repeat off" : "Repeat all")
        : (session.repeatMode === "context"
          ? (session.canToggleRepeatTrack ? "Repeat this track" : "Turn repeat off")
          : "Repeat all")
    );
    dom.seek.disabled = !session.canSeek;
    ambient.setPlaying(isPlaying);
  }

  function applySession(payload) {
    const now = performance.now();
    // The native stamp is wall-clock epoch, not the browser's estimated
    // monotonic epoch (which can diverge after a device clock adjustment).
    // Use wall time only for bounded transit age; animate with performance.now.
    const incoming = model.normalizeSession(payload, now, Date.now());
    if (incoming.transportExpired) {
      if (!state.awaitingTransportResync) post("resync");
      state.awaitingTransportResync = true;
      return;
    }
    state.awaitingTransportResync = false;
    if (!model.shouldAcceptSession(state.session, incoming)) return;
    const changed = !state.session
      || incoming.trackId !== state.session.trackId
      || incoming.generation !== state.session.generation;
    state.seekPreview = model.reconcileSeekPreview(state.seekPreview, incoming, now);
    state.session = incoming;
    if (changed) {
      state.rawLyrics = null;
      state.lyricsTrackId = "";
      state.lyricsGeneration = "";
      state.lyricsType = "unknown";
      state.lines = [];
      state.activeLine = -1;
      state.followLyrics = true;
      state.draggingSeek = false;
      state.seekPreview = null;
      updateFollowButton();
      showLoading();
    }
    applyTrack(incoming.track);
    applyControls();
    if (state.lifecyclePhase === "visible"
        && !document.hidden
        && !incoming.requiresFreshObservation) {
      state.lifecycleFrozen = false;
      state.frozenPositionMs = incoming.positionMs;
    } else if (!state.lifecycleFrozen) {
      state.frozenPositionMs = incoming.positionMs;
    }
    reconcileCommands();
    if (changed) {
      [...state.pendingCommands.keys()].forEach(settleCommand);
    }
  }

  function renderLyrics(raw, trackId, generation) {
    state.rawLyrics = raw;
    state.lyricsTrackId = String(trackId || "");
    state.lyricsGeneration = String(generation || "");
    const normalized = model.normalizeLyrics(raw, {
      durationMs: state.session?.durationMs || 0
    });
    state.lyricsType = normalized.type;
    state.lines = normalized.lines;
    state.activeLine = -1;
    dom.lyrics.dataset.timing = normalized.timing;
    dom.lyrics.replaceChildren();

    if (!state.lines.length) {
      showLyricsState("No lyrics are available for this track.", true);
      return;
    }

    state.lines.forEach((line, index) => {
      const timed = Number.isFinite(line.start) && Number.isFinite(line.end);
      const element = document.createElement(timed && line.kind !== "interlude" ? "button" : "div");
      element.className = `lyric-line ${line.kind}`;
      if (timed && line.kind === "lead" && !line.tokens.length) {
        element.classList.add("line-timed");
      }
      if (line.opposite) element.classList.add("opposite");
      if (line.rtl) element.classList.add("rtl");
      element.dataset.index = String(index);

      if (element instanceof HTMLButtonElement) {
        element.type = "button";
        element.setAttribute("aria-label", state.surface === "fullscreen"
          ? `Seek to ${formatTime(line.start)}: ${line.text}` : `Open lyrics: ${line.text}`);
        element.addEventListener("click", () => state.surface === "fullscreen"
          ? startSeek(line.start, element) : post("openFullscreen"));
      }

      if (line.kind === "interlude") {
        element.setAttribute("aria-hidden", "true");
        for (let dot = 0; dot < 3; dot++) {
          const marker = document.createElement("span");
          marker.className = "dot";
          element.appendChild(marker);
        }
      } else if (line.tokens.length) {
        const lineText = document.createElement("span");
        lineText.className = "line-text";
        model.groupTokens(line.tokens).forEach((group) => {
          const word = document.createElement("span");
          word.className = "word-group";
          if (group.spaceBefore) lineText.appendChild(document.createTextNode(" "));
          group.tokens.forEach((token) => {
            const tokenElement = document.createElement("span");
            tokenElement.className = "token";
            const transliteration = String(token.transliterated || "").trim();
            const text = state.preferences.romanized && transliteration
              ? transliteration
              : token.text;
            tokenElement.textContent = text;
            tokenElement.dataset.text = text;
            token.element = tokenElement;
            word.appendChild(tokenElement);
          });
          lineText.appendChild(word);
        });
        element.appendChild(lineText);
      } else {
        const lineText = document.createElement("span");
        lineText.className = "line-text";
        lineText.textContent = state.preferences.romanized && line.romanizedText
          ? line.romanizedText
          : line.text;
        element.appendChild(lineText);
      }

      if (state.preferences.translations && line.translation) {
        const translation = document.createElement("span");
        translation.className = "line-translation";
        translation.textContent = line.translation;
        element.appendChild(translation);
      }
      line.element = element;
      dom.lyrics.appendChild(element);
    });

    dom.lyricState.hidden = true;
    dom.app.setAttribute("aria-busy", "false");
    const timedLines = state.lines.filter((line) => Number.isFinite(line.start));
    post("diagnostic", {
      kind: "lyricsNormalized",
      trackId: state.lyricsTrackId,
      generation: state.lyricsGeneration,
      lyricsType: normalized.type,
      lineCount: state.lines.length,
      timedLineCount: timedLines.length,
      firstStartMs: timedLines[0]?.start ?? -1,
      lastEndMs: timedLines[timedLines.length - 1]?.end ?? -1
    });
    requestAnimationFrame(() => {
      fitWordGroups();
      updateLyrics(positionNow(), true);
    });
  }

  function fitWordGroups() {
    if (state.surface === "inline") {
      const root = document.documentElement;
      root.style.setProperty("--inline-fit", "1");
      const line = dom.lyrics.querySelector(".lyric-line:not(.interlude)");
      const rowHeight = line ? parseFloat(getComputedStyle(line).lineHeight) : 0;
      const available = dom.scroller.clientHeight;
      if (rowHeight > 0 && available > 0) {
        const fit = Math.min(1, available / rowHeight);
        root.style.setProperty("--inline-fit", String(fit));
        root.style.setProperty("--inline-lines", String(Math.max(1,
          Math.min(2, Math.floor(available / (rowHeight * fit) + 0.001)))));
      }
    }
    // Keep ordinary joined syllables together. Only an over-wide group may
    // wrap at its real token boundaries; a single huge token can wrap within
    // its own box without changing its timestamps or text.
    const groups = [...dom.lyrics.querySelectorAll(".word-group")];
    groups.forEach((group) => group.classList.remove("breakable"));
    const oversized = groups.filter((group) => (
      group.offsetWidth > group.parentElement.clientWidth - 1
    ));
    oversized.forEach((group) => group.classList.add("breakable"));
  }

  function updateLyrics(rawPosition, forceScroll = false) {
    if (!state.lines.length) return;
    const position = rawPosition - state.preferences.playbackOffset;
    const activeIndex = model.findActiveLine(state.lines, position);
    const inlineIndex = activeIndex >= 0 ? activeIndex : state.lines.findIndex(
      (line) => line.kind !== "interlude" && line.kind !== "background");
    state.lines.forEach((line, index) => {
      const visualState = model.lineVisualState(line, index, activeIndex, position);
      const active = visualState === "active";
      line.element?.classList.toggle("active", active);
      line.element?.classList.toggle("sung", visualState === "sung");
      line.element?.classList.toggle("not-sung", visualState === "not-sung");
      if (state.surface === "inline") line.element?.classList.toggle("inline-visible", index === inlineIndex);
      if (line.kind === "lead" && line.element) {
        if (active) line.element.setAttribute("aria-current", "true");
        else line.element.removeAttribute("aria-current");
      }
    });

    if (activeIndex !== state.activeLine) {
      state.activeLine = activeIndex;
      if (state.followLyrics && activeIndex >= 0) scrollToLine(activeIndex);
    } else if (forceScroll && state.followLyrics && activeIndex >= 0) {
      scrollToLine(activeIndex);
    }

    const startIndex = Math.max(0, activeIndex - 5);
    const endIndex = Math.min(state.lines.length, Math.max(activeIndex + 7, 10));
    for (let index = startIndex; index < endIndex; index++) {
      const line = state.lines[index];
      if (line.kind === "interlude") {
        const dots = line.element?.children || [];
        const segment = Math.max(1, (line.end - line.start) / 3);
        [...dots].forEach((dot, dotIndex) => {
          const progress = model.clamp(
            (position - (line.start + dotIndex * segment)) / segment
          );
          dot.style.setProperty("--fill-number", progress.toFixed(3));
        });
      }
      (line.tokens || []).forEach((token) => {
        if (!token.element) return;
        const progress = model.tokenProgress(token, position);
        const pulse = progress > 0 && progress < 1 ? Math.sin(progress * Math.PI) : 0;
        token.element.style.setProperty("--fill", `${(progress * 100).toFixed(2)}%`);
        token.element.style.setProperty("--pulse", reduceMotion() ? "0" : pulse.toFixed(3));
      });
    }
  }

  function scrollToLine(index) {
    if (state.surface === "inline") return;
    const element = state.lines[index]?.element;
    if (!element) return;
    const target = element.offsetTop
      - dom.scroller.clientHeight * (state.surface === "card" ? .28 : .42)
      + element.offsetHeight * .5;
    const immediate = reduceMotion() || state.draggingSeek || Boolean(state.seekPreview);
    dom.scroller.style.scrollBehavior = immediate ? "auto" : "smooth";
    dom.scroller.scrollTo({
      top: Math.max(0, target),
      // Scrubbing follows the finger immediately. Restarting a smooth scroll
      // for every changed lyric makes it chase an obsolete target.
      behavior: immediate ? "auto" : "smooth"
    });
  }

  function animationFrame() {
    const position = positionNow();
    const duration = Math.max(1, state.session?.durationMs || 1);
    updateLyrics(position);
    if (!state.draggingSeek) {
      dom.seek.max = String(duration);
      dom.seek.value = String(model.clamp(position, 0, duration));
      dom.seek.style.setProperty(
        "--seek-progress",
        `${model.clamp(position / duration) * 100}%`
      );
      dom.elapsed.textContent = formatTime(position);
    }
    dom.duration.textContent = formatTime(duration);
    reconcileCommands();
    requestAnimationFrame(animationFrame);
  }

  function savePreferences() {
    try {
      localStorage.setItem("spicy-ios-preferences", JSON.stringify(state.preferences));
    } catch (_) {}
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
    document.documentElement.style.setProperty(
      "--lyric-scale",
      String(state.preferences.fontSize / 100)
    );
    ambient.setEnabled(state.surface === "fullscreen" && state.preferences.dynamicBackground && !reduceMotion());
    if (rerender && state.rawLyrics) {
      renderLyrics(state.rawLyrics, state.lyricsTrackId, state.lyricsGeneration);
    } else if (state.lines.length) {
      requestAnimationFrame(fitWordGroups);
    }
    savePreferences();
  }

  let settingsReturnFocus = null;

  function setSettingsOpen(open) {
    const wasOpen = !dom.settingsSheet.hidden;
    if (open === wasOpen) return;
    if (open) settingsReturnFocus = document.activeElement;
    dom.settingsSheet.hidden = !open;
    dom.settingsScrim.hidden = !open;
    dom.settings.setAttribute("aria-expanded", String(open));
    dom.app.inert = open;
    dom.app.setAttribute("aria-hidden", String(open));
    if (open) requestAnimationFrame(() => dom.settingsClose.focus());
    else {
      const destination = settingsReturnFocus instanceof HTMLElement
        ? settingsReturnFocus
        : dom.settings;
      settingsReturnFocus = null;
      requestAnimationFrame(() => destination.focus());
    }
  }

  function updateFollowButton() {
    dom.resumeScroll.hidden = state.followLyrics;
  }

  window.SpicyNative = {
    receive(event) {
      if (!event || typeof event !== "object") return;
      const payload = event.payload || {};
      switch (event.type) {
      case "bootstrap":
        state.surface = ["card", "inline"].includes(payload.surface) ? payload.surface : "fullscreen";
        document.documentElement.dataset.surface = state.surface;
        state.nativeReduceMotion = Boolean(payload.reduceMotion);
        if (payload.preferences && typeof payload.preferences === "object") {
          state.preferences.romanized = Boolean(payload.preferences.romanized);
          state.preferences.translations = payload.preferences.translations !== false;
          state.preferences.dynamicBackground = payload.preferences.dynamicBackground !== false;
          state.preferences.fontSize = model.clamp(
            model.finite(payload.preferences.fontSize, 100),
            82,
            126
          );
          state.preferences.playbackOffset = model.clamp(
            model.finite(payload.preferences.playbackOffset),
            -5000,
            5000
          );
        }
        document.body.classList.toggle("native-reduce-motion", state.nativeReduceMotion);
        applyPreferences();
        break;
      case "session":
        applySession(payload);
        break;
      case "lyrics":
        if (!model.shouldAcceptLyrics(state.session, payload)) break;
        if (payload.state === "loading") showLoading();
        else if (payload.state === "ready") {
          renderLyrics(payload.data, payload.trackId, payload.generation);
        } else {
          showLyricsState(payload.message || "Lyrics are temporarily unavailable.", true);
        }
        break;
      case "lifecycle":
        if (payload.state === "hidden" || payload.state === "resuming") {
          state.frozenPositionMs = positionNow();
          state.lifecyclePhase = payload.state;
          state.lifecycleFrozen = true;
        } else if (payload.state === "visible"
            && state.session
            && !state.session.requiresFreshObservation) {
          state.lifecyclePhase = "visible";
          state.frozenPositionMs = state.session.positionMs;
          state.lifecycleFrozen = false;
        } else if (payload.state === "visible") {
          state.lifecyclePhase = "visible";
        }
        break;
      case "commandResult":
        acknowledgeCommand(payload);
        break;
      }
    }
  };

  dom.close.addEventListener("click", () => post("close", {}, dom.close));
  dom.play.addEventListener("click", () => {
    const playing = state.session?.isPlaying && !state.session?.isPaused;
    post(playing ? "pause" : "play", {}, dom.play);
  });
  dom.shuffle.addEventListener("click", () => post("toggleShuffle", {}, dom.shuffle));
  dom.previous.addEventListener("click", () => post("previous", {}, dom.previous, 8000));
  dom.next.addEventListener("click", () => post("next", {}, dom.next, 8000));
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
    if (moved || scrolled) {
      state.followLyrics = false;
      updateFollowButton();
    }
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
    state.followLyrics = true;
    updateFollowButton();
    state.dragPositionMs = model.finite(dom.seek.value);
    const maximum = Math.max(1, model.finite(dom.seek.max, 1));
    dom.seek.style.setProperty(
      "--seek-progress",
      `${model.clamp(state.dragPositionMs / maximum) * 100}%`
    );
    dom.elapsed.textContent = formatTime(state.dragPositionMs);
    updateLyrics(state.dragPositionMs, true);
  });
  dom.seek.addEventListener("change", () => {
    if (!state.draggingSeek) return;
    const target = state.dragPositionMs;
    state.draggingSeek = false;
    startSeek(target, dom.seek);
  });
  const cancelSeekDrag = () => {
    if (!state.draggingSeek) return;
    state.draggingSeek = false;
    state.seekPreview = null;
    updateLyrics(positionNow(), true);
  };
  dom.seek.addEventListener("pointercancel", cancelSeekDrag);
  dom.seek.addEventListener("keydown", (event) => {
    if (event.key === "Escape") { event.preventDefault(); cancelSeekDrag(); }
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
    post("setPreference", {
      key: "dynamicBackground",
      value: state.preferences.dynamicBackground
    });
  });
  dom.fontSize.addEventListener("input", () => {
    state.preferences.fontSize = model.clamp(model.finite(dom.fontSize.value, 100), 82, 126);
    applyPreferences();
  });
  dom.fontSize.addEventListener("change", () => post("setPreference", {
    key: "fontSize",
    value: state.preferences.fontSize
  }));
  dom.playbackOffset.addEventListener("input", () => {
    state.preferences.playbackOffset = model.clamp(
      model.finite(dom.playbackOffset.value),
      -5000,
      5000
    );
    applyPreferences();
    updateLyrics(positionNow(), true);
  });
  dom.playbackOffset.addEventListener("change", () => post("setPreference", {
    key: "playbackOffset",
    value: state.preferences.playbackOffset
  }));

  addEventListener("keydown", (event) => {
    const settingsOpen = !dom.settingsSheet.hidden;
    if (event.key === "Escape" && settingsOpen) {
      event.preventDefault();
      setSettingsOpen(false);
      return;
    }
    if (event.key !== "Tab" || !settingsOpen) return;
    const focusable = [...dom.settingsSheet.querySelectorAll(
      'button:not([disabled]), input:not([disabled]), [tabindex]:not([tabindex="-1"])'
    )].filter((element) => !element.hidden);
    if (!focusable.length) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  });
  let resizeFrame = 0;
  addEventListener("resize", () => {
    cancelAnimationFrame(resizeFrame);
    resizeFrame = requestAnimationFrame(() => {
      fitWordGroups();
      updateLyrics(positionNow(), true);
    });
  }, { passive: true });
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
      state.frozenPositionMs = positionNow();
      state.lifecyclePhase = "hidden";
      state.lifecycleFrozen = true;
    } else {
      state.frozenPositionMs = positionNow();
      state.lifecyclePhase = "resuming";
      state.lifecycleFrozen = true;
      post("resync");
    }
  }, { passive: true });
  prefersReducedMotion.addEventListener?.("change", () => applyPreferences());

  applyPreferences();
  showLoading();
  requestAnimationFrame(animationFrame);
  post("ready", { rendererProtocolVersion: RENDERER_PROTOCOL_VERSION });
})();
