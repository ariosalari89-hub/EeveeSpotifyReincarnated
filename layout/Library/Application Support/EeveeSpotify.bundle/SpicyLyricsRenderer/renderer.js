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
    seekControl: $("#seek-control"),
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
    trackPresentationKey: null,
    rawLyrics: null,
    lyricsTrackId: "",
    lyricsGeneration: "",
    lyricsType: "unknown",
    lines: [],
    activeLine: -1,
    captionIndex: -1,
    captionMotion: null,
    cardScroll: null,
    lastLyricPosition: null,
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
      if (this.enabled && this.playing && state.lifecyclePhase === "visible"
          && !document.hidden && timestamp - this.lastFrame >= frameInterval) {
        this.phase += Math.min(100, timestamp - this.lastFrame) * .000045;
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
    stopEmbeddedMotion();
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
    stopEmbeddedMotion();
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
    const artwork = String(track?.artwork || "");
    const dominantColor = String(track?.dominantColor || "");
    // Playback observations are frequent; metadata and artwork are not. Avoid
    // decoding/sampling the same image and rebuilding five labels per heartbeat.
    const key = JSON.stringify([title, artist, album, artwork, dominantColor, state.surface]);
    if (state.trackPresentationKey === key) return;
    state.trackPresentationKey = key;
    dom.title.textContent = title;
    dom.artist.textContent = artist;
    dom.album.textContent = album;
    dom.miniTitle.textContent = title;
    dom.miniArtist.textContent = artist;
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
    if (state.surface === "fullscreen") ambient.setArtwork(artwork, dominantColor);
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
    if (!session.canSeek) cancelSeekDrag();
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
      cancelSeekDrag();
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
    stopEmbeddedMotion();
    state.captionIndex = -1;
    state.lastLyricPosition = null;
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
    state.lastLyricPosition = null;
    if (state.surface === "inline") {
      state.lines.forEach(line => { delete line.captionLayout; });
      updateLyrics(positionNow());
      return;
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

  function cancelCaptionMotion() {
    const motion = state.captionMotion;
    state.captionMotion = null;
    if (!motion) return;
    motion.incoming.cancel();
    motion.outgoing.cancel();
    motion.ghost.remove();
  }

  function stopEmbeddedMotion() {
    cancelCaptionMotion();
    state.cardScroll = null;
    if (state.surface === "card") {
      const top = dom.scroller.scrollTop;
      dom.scroller.style.scrollBehavior = "auto";
      dom.scroller.scrollTo({ top, behavior: "auto" });
    }
  }

  function snapshotCaption(line) {
    cancelCaptionMotion();
    if (!line?.element || reduceMotion() || state.lifecyclePhase !== "visible" || document.hidden) return null;
    const rect = line.element.getBoundingClientRect();
    if (!rect.width || !rect.height) return null;
    const parent = dom.scroller.parentElement;
    const bounds = parent.getBoundingClientRect();
    const ghost = line.element.cloneNode(true);
    ghost.classList.add("caption-outgoing");
    ghost.removeAttribute("aria-current");
    ghost.setAttribute("aria-hidden", "true");
    ghost.inert = true;
    ghost.tabIndex = -1;
    Object.assign(ghost.style, {
      position: "absolute", left: `${rect.left - bounds.left}px`, top: `${rect.top - bounds.top}px`,
      width: `${rect.width}px`, height: `${rect.height}px`, margin: "0", pointerEvents: "none"
    });
    parent.appendChild(ghost);
    return ghost;
  }

  function blendCaption(ghost, line) {
    if (!ghost) return;
    if (!line?.element || reduceMotion()) { ghost.remove(); return; }
    const options = { duration: 180, easing: "ease-out" };
    const motion = {
      ghost,
      incoming: line.element.animate([{ opacity: 0 }, { opacity: 1 }], options),
      outgoing: ghost.animate([{ opacity: 1 }, { opacity: 0 }], options)
    };
    state.captionMotion = motion;
    motion.incoming.onfinish = () => {
      if (state.captionMotion === motion) cancelCaptionMotion();
    };
  }

  function layoutCaption(line, position, beforePageChange) {
    const text = line?.element?.querySelector(".line-text");
    if (!text) return;
    const available = Math.max(1, dom.scroller.clientHeight - 6);
    const key = `${dom.scroller.clientWidth}:${available}:${state.preferences.fontSize}`;
    if (line.captionLayout?.key !== key) {
      const groups = [...text.querySelectorAll(".word-group")];
      line.element.style.setProperty("--inline-fit", "1");
      groups.forEach(g => { g.hidden = false; });
      const pages = [];
      // Keep full phrases when they fit; otherwise use word-boundary pages,
      // selected by the provider's actual token time, never an invented timer.
      if (text.offsetHeight > available && groups.length > 1) {
        groups.forEach(g => { g.hidden = true; });
        let page = [];
        for (const group of groups) {
          group.hidden = false;
          if (page.length && text.offsetHeight > available) {
            group.hidden = true;
            pages.push(page);
            page.forEach(g => { g.hidden = true; });
            page = [];
            group.hidden = false;
          }
          page.push(group);
        }
        if (page.length) pages.push(page);
      } else pages.push(groups);
      line.captionLayout = { key, pages, page: -1 };
    }
    const layout = line.captionLayout;
    const token = line.tokens.find(t => position < t.end) || line.tokens.at(-1);
    const group = token?.element?.parentElement;
    const pageIndex = Math.max(0, layout.pages.findIndex(page => page.includes(group)));
    if (layout.page === pageIndex) return;
    if (layout.page >= 0) beforePageChange?.();
    layout.page = pageIndex;
    const current = layout.pages[pageIndex];
    text.querySelectorAll(".word-group").forEach(g => { g.hidden = !current.includes(g); });
    // A line-timed lyric (or one very long provider token) has no finer timing.
    // Fit the complete text, without ellipsis or fabricated syllable timing.
    line.element.style.setProperty("--inline-fit", "1");
    let low = .1, high = 1;
    if (text.offsetHeight > available) {
      for (let i = 0; i < 9; i++) {
        const mid = (low + high) / 2;
        line.element.style.setProperty("--inline-fit", String(mid));
        if (text.offsetHeight <= available) low = mid; else high = mid;
      }
      line.element.style.setProperty("--inline-fit", String(low));
    }
  }

  function updateLyrics(rawPosition, forceScroll = false) {
    if (!state.lines.length) return;
    const position = rawPosition - state.preferences.playbackOffset;
    if (!forceScroll && position === state.lastLyricPosition) return;
    state.lastLyricPosition = position;
    const activeIndex = model.findActiveLine(state.lines, position);
    const inlineIndex = state.surface === "inline"
      ? model.findCaptionLine(state.lines, position, activeIndex) : -1;
    let captionGhost = null;
    if (state.surface === "inline" && state.captionIndex !== inlineIndex && !forceScroll) {
      captionGhost = snapshotCaption(state.lines[state.captionIndex]);
    }
    state.lines.forEach((line, index) => {
      const visualState = model.lineVisualState(line, index, activeIndex, position);
      const active = visualState === "active";
      if (line.visualState !== visualState) {
        line.visualState = visualState;
        line.element?.classList.toggle("active", active);
        line.element?.classList.toggle("sung", visualState === "sung");
        line.element?.classList.toggle("not-sung", visualState === "not-sung");
        if (line.kind === "lead" && line.element) {
          if (active) line.element.setAttribute("aria-current", "true");
          else line.element.removeAttribute("aria-current");
        }
      }
      if (state.surface === "inline" && line.captionVisible !== (index === inlineIndex)) {
        line.captionVisible = index === inlineIndex;
        line.element?.classList.toggle("inline-visible", line.captionVisible);
      }
    });

    if (state.surface === "inline") {
      const line = state.lines[inlineIndex];
      layoutCaption(line, position, () => {
        if (!forceScroll && state.captionIndex === inlineIndex) captionGhost = snapshotCaption(line);
      });
      state.captionIndex = inlineIndex;
      blendCaption(captionGhost, line);
    }

    if (activeIndex !== state.activeLine) {
      const firstLine = state.activeLine < 0;
      state.activeLine = activeIndex;
      if (state.followLyrics && activeIndex >= 0) scrollToLine(activeIndex, firstLine || forceScroll);
    } else if (forceScroll && state.followLyrics && activeIndex >= 0) {
      scrollToLine(activeIndex, true);
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
          const fill = progress.toFixed(3);
          if (dot.spicyFill !== fill) {
            dot.spicyFill = fill;
            dot.style.setProperty("--fill-number", fill);
          }
        });
      }
      (line.tokens || []).forEach((token) => {
        if (!token.element) return;
        const progress = model.tokenProgress(token, position);
        const pulse = progress > 0 && progress < 1 ? Math.sin(progress * Math.PI) : 0;
        const fill = `${(progress * 100).toFixed(2)}%`;
        const lift = reduceMotion() || state.surface !== "fullscreen" ? "0" : pulse.toFixed(3);
        if (token.paintFill !== fill) {
          token.paintFill = fill;
          token.element.style.setProperty("--fill", fill);
        }
        if (token.paintPulse !== lift) {
          token.paintPulse = lift;
          token.element.style.setProperty("--pulse", lift);
        }
      });
    }
  }

  function scrollToLine(index, snap = false) {
    if (state.surface === "inline") return;
    const element = state.lines[index]?.element;
    if (!element) return;
    const target = dom.scroller.scrollTop + element.getBoundingClientRect().top
      - dom.scroller.getBoundingClientRect().top
      - dom.scroller.clientHeight * (state.surface === "card" ? .28 : .42)
      + element.offsetHeight * .5;
    const immediate = reduceMotion() || state.draggingSeek || Boolean(state.seekPreview);
    if (state.surface === "card") {
      const to = model.clamp(target, 0, Math.max(0, dom.scroller.scrollHeight - dom.scroller.clientHeight));
      dom.scroller.style.scrollBehavior = "auto";
      if (immediate || snap || state.lifecyclePhase !== "visible") {
        state.cardScroll = null;
        dom.scroller.scrollTo({ top: to, behavior: "auto" });
      } else if (Math.abs(to - dom.scroller.scrollTop) > 1) {
        state.cardScroll = { from: dom.scroller.scrollTop, to, started: performance.now() };
      }
      return;
    }
    dom.scroller.style.scrollBehavior = immediate ? "auto" : "smooth";
    dom.scroller.scrollTo({
      top: Math.max(0, target),
      // Scrubbing follows the finger immediately. Restarting a smooth scroll
      // for every changed lyric makes it chase an obsolete target.
      behavior: immediate ? "auto" : "smooth"
    });
  }

  function animationFrame() {
    requestAnimationFrame(animationFrame);
    if (state.lifecyclePhase !== "visible" || document.hidden) return;
    const position = positionNow();
    const duration = Math.max(1, state.session?.durationMs || 1);
    updateLyrics(position);
    if (state.cardScroll) {
      const scroll = state.cardScroll;
      const progress = model.clamp((performance.now() - scroll.started) / 320);
      const eased = 1 - Math.pow(1 - progress, 3);
      dom.scroller.scrollTo({ top: scroll.from + (scroll.to - scroll.from) * eased, behavior: "auto" });
      if (progress === 1) state.cardScroll = null;
    }
    if (!state.draggingSeek) {
      if (dom.seek.max !== String(duration)) dom.seek.max = String(duration);
      dom.seek.value = String(model.clamp(position, 0, duration));
      dom.seek.style.setProperty(
        "--seek-progress",
        `${model.clamp(position / duration) * 100}%`
      );
      const elapsed = formatTime(position);
      if (dom.elapsed.textContent !== elapsed) dom.elapsed.textContent = elapsed;
      const valueText = `${elapsed} of ${formatTime(duration)}`;
      if (dom.seek.getAttribute("aria-valuetext") !== valueText) dom.seek.setAttribute("aria-valuetext", valueText);
    }
    const formattedDuration = formatTime(duration);
    if (dom.duration.textContent !== formattedDuration) dom.duration.textContent = formattedDuration;
    reconcileCommands();
  }

  function savePreferences() {
    try {
      localStorage.setItem("spicy-ios-preferences", JSON.stringify(state.preferences));
    } catch (_) {}
  }

  function applyPreferences({ rerender = false } = {}) {
    if (reduceMotion()) stopEmbeddedMotion();
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
    if (open) { cancelSeekDrag(); settingsReturnFocus = document.activeElement; }
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
        stopEmbeddedMotion();
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
          stopEmbeddedMotion();
          cancelSeekDrag();
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
  dom.scroller.addEventListener("click", (event) => {
    // Timed lyric buttons handle themselves. Untimed text, empty preview
    // space and interludes must still open the readable full-screen surface.
    if (state.surface !== "fullscreen" && !event.target.closest("button")) post("openFullscreen");
  });
  dom.scroller.addEventListener("keydown", (event) => {
    if (state.surface !== "fullscreen" && event.target === dom.scroller && event.key === "Enter") {
      event.preventDefault();
      post("openFullscreen");
    }
  });
  dom.scroller.addEventListener("pointerdown", (event) => {
    if (state.surface !== "fullscreen") return;
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
    if (state.surface !== "fullscreen") return;
    state.followLyrics = false;
    updateFollowButton();
  }, { passive: true });

  // Compact previews are followers, not a second manually browsable lyric
  // screen. Native parent scrolling must never disable their hidden follow UI.
  dom.scroller.addEventListener("scroll", () => {
    if (state.surface === "card" && state.activeLine >= 0 && !state.cardScroll) {
      const active = state.lines[state.activeLine]?.element;
      const rect = active?.getBoundingClientRect();
      const bounds = dom.scroller.getBoundingClientRect();
      if (rect && (rect.bottom < bounds.top || rect.top > bounds.bottom)) scrollToLine(state.activeLine);
    }
  }, { passive: true });

  let seekDrag = null;
  function paintSeekDrag(position) {
    dom.seek.value = String(position);
    state.dragPositionMs = Number(dom.seek.value);
    dom.seek.style.setProperty("--seek-progress",
      `${model.clamp(state.dragPositionMs / Math.max(1, Number(dom.seek.max))) * 100}%`);
    dom.elapsed.textContent = formatTime(state.dragPositionMs);
    dom.seek.setAttribute("aria-valuetext", `${formatTime(state.dragPositionMs)} of ${formatTime(state.session?.durationMs)}`);
    updateLyrics(state.dragPositionMs, true);
  }

  function cancelSeekDrag() {
    const drag = seekDrag;
    seekDrag = null;
    if (drag && dom.seekControl.hasPointerCapture(drag.pointerId)) {
      dom.seekControl.releasePointerCapture(drag.pointerId);
    }
    if (!state.draggingSeek) return;
    state.draggingSeek = false;
    state.seekPreview = null;
    updateLyrics(positionNow(), true);
  }

  function moveSeekDrag(event) {
    if (!seekDrag || event.pointerId !== seekDrag.pointerId) return;
    event.preventDefault();
    const position = model.clamp((event.clientX - seekDrag.left - seekDrag.offset) / seekDrag.travel) * seekDrag.maximum;
    if (Math.abs(position - seekDrag.startPosition) >= 50) seekDrag.changed = true;
    paintSeekDrag(position);
  }

  dom.seekControl.addEventListener("pointerdown", (event) => {
    if (event.button !== 0 || !event.isPrimary || seekDrag || !state.session?.canSeek
        || state.lifecyclePhase !== "visible") return;
    event.preventDefault();
    const position = positionNow();
    [...state.pendingCommands.entries()].forEach(([id, pending]) => {
      if (pending.type === "seek") settleCommand(id);
    });
    state.seekPreview = null;
    state.draggingSeek = true;
    state.dragPositionMs = position;
    const rect = dom.seek.getBoundingClientRect();
    const maximum = Math.max(1, state.session.durationMs);
    const left = rect.left + 7, travel = Math.max(1, rect.width - 14);
    const thumb = left + model.clamp(position / maximum) * travel;
    seekDrag = {
      pointerId: event.pointerId, generation: state.session.generation,
      maximum, left, travel, startPosition: position, changed: false,
      offset: Math.abs(event.clientX - thumb) <= 22 ? event.clientX - thumb : 0
    };
    dom.seek.max = String(maximum);
    state.followLyrics = true;
    updateFollowButton();
    dom.seekControl.setPointerCapture(event.pointerId);
    dom.seek.focus({ preventScroll: true });
    dom.seekControl.classList.add("pointer-input");
    moveSeekDrag(event);
  });
  dom.seekControl.addEventListener("pointermove", moveSeekDrag);
  dom.seekControl.addEventListener("pointerup", (event) => {
    if (!seekDrag || event.pointerId !== seekDrag.pointerId) return;
    moveSeekDrag(event);
    const commit = seekDrag.changed && seekDrag.generation === state.session?.generation
      && state.session?.canSeek && state.lifecyclePhase === "visible";
    const target = state.dragPositionMs;
    cancelSeekDrag();
    if (commit) startSeek(target, dom.seek);
  });
  dom.seekControl.addEventListener("pointercancel", cancelSeekDrag);
  dom.seekControl.addEventListener("lostpointercapture", cancelSeekDrag);
  dom.seekControl.addEventListener("contextmenu", (event) => event.preventDefault());
  dom.seek.addEventListener("input", () => {
    if (seekDrag || !state.session?.canSeek) return;
    state.draggingSeek = true;
    state.followLyrics = true;
    updateFollowButton();
    paintSeekDrag(Number(dom.seek.value));
  });
  dom.seek.addEventListener("change", () => {
    if (seekDrag || !state.draggingSeek) return;
    const target = state.dragPositionMs;
    state.draggingSeek = false;
    startSeek(target, dom.seek);
  });
  dom.seek.addEventListener("keydown", (event) => {
    if (event.key === "Escape") { event.preventDefault(); cancelSeekDrag(); }
  });
  dom.seek.addEventListener("focus", () => dom.seekControl.classList.remove("pointer-input"));

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
    dom.seekControl.classList.remove("pointer-input");
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
    cancelSeekDrag();
    stopEmbeddedMotion();
    cancelAnimationFrame(resizeFrame);
    resizeFrame = requestAnimationFrame(() => {
      fitWordGroups();
      updateLyrics(positionNow(), true);
    });
  }, { passive: true });
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
      stopEmbeddedMotion();
      cancelSeekDrag();
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
