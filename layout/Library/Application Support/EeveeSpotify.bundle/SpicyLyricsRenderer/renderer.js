(() => {
  "use strict";

  const RENDERER_PROTOCOL_VERSION = 5;
  const model = window.SpicyLyricsModel;
  if (!model) throw new Error("Spicy Lyrics renderer model is missing");
  const effects = window.SpicyLyricsEffects;
  if (!effects) throw new Error("Spicy Lyrics renderer effects are missing");

  const $ = (selector) => document.querySelector(selector);
  const dom = {
    app: $("#app"),
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
    lyricsContentKey: "",
    lyricsTrackId: "",
    lyricsGeneration: "",
    lyricsType: "unknown",
    lines: [],
    activeLine: -1,
    captionIndex: -1,
    captionMotion: null,
    cardScroll: null,
    hasPositionedLyrics: false,
    lastLyricPosition: null,
    lastEffectsTime: null,
    effectsMoving: false,
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
    if (pending.type === "toggleShuffle") applyControls();
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
    if (pending.accepted) reconcileCommands();
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

  class ArtworkBackground {
    constructor(layer) {
      this.layer = layer;
      this.artwork = "";
      this.artworkRequest = 0;
      this.enabled = true;
      this.playing = false;
      this.ready = false;
    }

    setEnabled(enabled) { this.enabled = enabled; this.syncMotion(); }
    setPlaying(playing) { this.playing = playing; this.syncMotion(); }

    syncMotion() {
      this.layer.classList.toggle("is-animated", this.ready && this.enabled && this.playing
        && state.surface !== "inline" && state.lifecyclePhase === "visible"
        && !document.hidden && !reduceMotion());
    }

    setArtwork(url) {
      if (this.artwork === url) return;
      this.artwork = url;
      const request = ++this.artworkRequest;
      this.ready = false;
      this.layer.style.backgroundImage = "none";
      this.syncMotion();
      if (!url) return;
      const image = new Image();
      image.decoding = "async";
      image.onload = () => {
        if (request !== this.artworkRequest) return;
        this.layer.style.backgroundImage = `url(${JSON.stringify(url)})`;
        this.ready = true;
        this.syncMotion();
      };
      // A failed image stays on the neutral background, never the prior song.
      image.onerror = () => {
        if (request !== this.artworkRequest) return;
        this.ready = false;
        this.layer.style.backgroundImage = "none";
        this.syncMotion();
      };
      image.src = url;
    }
  }

  const ambient = new ArtworkBackground(dom.backdrop);

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
    // Playback observations are frequent; metadata and artwork are not. Avoid
    // decoding the same image and rebuilding five labels per heartbeat.
    const key = JSON.stringify([title, artist, album, artwork, state.surface]);
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
    } else {
      dom.cover.classList.remove("ready");
      dom.cover.alt = "";
      dom.cover.removeAttribute("src");
      dom.miniCover.removeAttribute("src");
    }
    ambient.setArtwork(state.surface !== "inline" ? artwork : "");
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
    const shuffleCommand = [...state.pendingCommands.values()].find(command => command.type === "toggleShuffle"
      && command.baseline?.generation === session.generation && command.baseline?.trackId === session.trackId);
    const shuffleMode = shuffleCommand && !model.commandObserved("toggleShuffle", shuffleCommand.baseline, session)
      ? shuffleCommand.baseline.shuffleMode : session.shuffleMode;
    dom.shuffle.dataset.mode = shuffleMode;
    dom.shuffle.classList.toggle("active", shuffleMode !== "off");
    dom.shuffle.setAttribute("aria-pressed", String(shuffleMode !== "off"));
    dom.shuffle.setAttribute(
      "aria-label",
      shuffleMode === "smart" ? "Smart Shuffle on. Change shuffle mode"
        : (shuffleMode === "shuffle"
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
    state.hasPositionedLyrics = false;
    state.captionIndex = -1;
    state.lastLyricPosition = null;
    state.rawLyrics = raw;
    state.lyricsContentKey = JSON.stringify(raw);
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
        const group = document.createElement("span");
        group.className = "dot-group";
        for (let dot = 0; dot < 3; dot++) {
          const marker = document.createElement("span");
          marker.className = "dot";
          marker.textContent = "•";
          group.appendChild(marker);
        }
        element.appendChild(group);
      } else if (line.tokens.length) {
        const lineText = document.createElement("span");
        lineText.className = "line-text";
        model.groupTokens(line.tokens).forEach((group) => {
          const word = document.createElement("span");
          word.className = "word-group";
          if (group.spaceBefore) {
            const space = document.createElement("span");
            space.className = "word-space";
            space.textContent = " ";
            lineText.appendChild(space);
          }
          group.tokens.forEach((token, tokenIndex) => {
            const tokenElement = document.createElement("span");
            tokenElement.className = "token";
            tokenElement.classList.toggle("joins-next", Boolean(token.joinsNext));
            tokenElement.classList.toggle("joins-previous", Boolean(group.tokens[tokenIndex - 1]?.joinsNext));
            const transliteration = String(token.transliterated || "").trim();
            const text = state.preferences.romanized && transliteration
              ? transliteration
              : token.text;
            token.letters = effects.letters(text, token.start, token.end, model.isRTL(text));
            if (token.letters.length) {
              tokenElement.classList.add("emphasis");
              token.letters.forEach(letter => {
                const glyph = document.createElement("span");
                glyph.className = "letter";
                if (!letter.text.trim()) glyph.classList.add("space-letter");
                glyph.textContent = letter.text;
                letter.element = glyph;
                tokenElement.appendChild(glyph);
              });
            } else tokenElement.textContent = text;
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
    state.lines.forEach(line => { line.dotEntrance?.cancel(); line.dotEntrance = null; });
    state.lastEffectsTime = null;
    state.effectsMoving = false;
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
    // A paged caption needs only its painted phrase in the frozen outgoing
    // layer, not every hidden word/letter and their compositor hints.
    ghost.querySelectorAll("[hidden]").forEach(node => node.remove());
    ghost.classList.remove("effects-near");
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
    const distance = Math.max(ghost.offsetHeight, line.element.offsetHeight) + 2;
    const motion = {
      ghost,
      incoming: line.element.animate([
        { opacity: 0, transform: `translateY(${distance}px)` }, { opacity: 1, transform: "translateY(0)" }
      ], options),
      outgoing: ghost.animate([
        { opacity: 1, transform: "translateY(0)" }, { opacity: 0, transform: `translateY(${-distance}px)` }
      ], options)
    };
    state.captionMotion = motion;
    motion.incoming.onfinish = () => {
      if (state.captionMotion === motion) cancelCaptionMotion();
    };
  }

  function layoutCaption(line, position, beforePageChange) {
    const text = line?.element?.querySelector(".line-text");
    if (!text) return;
    // Leave room for the desktop word/letter lift in the fixed native slot.
    // Fit the phrase instead of clipping or suppressing its spring motion.
    const available = Math.max(1, dom.scroller.clientHeight - 12);
    const key = `${dom.scroller.clientWidth}:${available}:${state.preferences.fontSize}`;
    const showGroups = visible => {
      text.querySelectorAll(".word-group").forEach(group => {
        group.hidden = !visible.includes(group);
        const space = group.previousElementSibling;
        if (space?.classList.contains("word-space")) {
          space.hidden = group.hidden || group === visible[0];
        }
      });
    };
    if (line.captionLayout?.key !== key) {
      const groups = [...text.querySelectorAll(".word-group")];
      line.element.style.setProperty("--inline-fit", "1");
      showGroups(groups);
      const pages = [];
      // Keep full phrases when they fit; otherwise use word-boundary pages,
      // selected by the provider's actual token time, never an invented timer.
      if (text.offsetHeight > available && groups.length > 1) {
        showGroups([]);
        let page = [];
        for (const group of groups) {
          showGroups([...page, group]);
          if (page.length && text.offsetHeight > available) {
            pages.push(page);
            page = [];
            showGroups([group]);
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
    showGroups(current);
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

  function previewHeldLine(position, activeIndex) {
    if (state.surface !== "card" || activeIndex >= 0) return -1;
    const index = model.findCaptionLine(state.lines, position, activeIndex);
    const line = state.lines[index];
    if (line?.kind !== "lead" || !Number.isFinite(line.end) || position < line.end) return -1;
    // Hold only the finished lead's appearance across a short handoff gap.
    // Pre-roll, post-roll and interludes keep their existing timing/state.
    const nextIsNear = state.lines.some(next => next.kind === "lead"
      && next.start > position && next.start - line.end < 3000);
    return nextIsNear ? index : -1;
  }

  function paintGlyphGradient(element, gradient) {
    element.style.setProperty("--gradient-position", gradient);
    const position = parseFloat(gradient);
    // Outside the sweep, the gradient is uniform across the glyph. Solid ink
    // preserves that alpha without allocating a separate text-gradient mask.
    element.classList.toggle("gradient-before", position <= -20);
    element.classList.toggle("gradient-after", position >= 100);
  }

  function paintEffects(owner, element, kind, progress, dt, snap, override, shouldPaint = true) {
    owner.effects ||= effects.create(kind);
    const target = override || effects.targets(kind, progress);
    if (reduceMotion()) Object.assign(target, { scale: 1, y: 0, glow: 0 });
    const value = effects.step(owner.effects, target, dt, snap);
    state.effectsMoving ||= value.moving;
    // Keep hidden caption spring state on the same clock, but defer its DOM
    // paint until that word's actual page becomes visible (including rewinds).
    if (!shouldPaint) return;
    const glow = Math.max(0, value.glow);
    const paint = {
      "--text-shadow-blur-radius": `${(4 + (kind === "dot" ? 6 : kind === "line" ? 8 : kind === "letter" ? 12 : 2) * glow).toFixed(3)}px`,
      "--text-shadow-opacity": Math.min(1, glow * (kind === "dot" ? .9 : kind === "line" ? .5 : kind === "letter" ? 1.85 : .35)).toFixed(4)
    };
    if (value.scale !== undefined) {
      paint["--effect-scale"] = value.scale.toFixed(5);
      paint["--effect-y"] = (value.y * (kind === "letter" ? 2 : 1)).toFixed(5);
    }
    if (value.opacity !== undefined) paint["--effect-opacity"] = value.opacity.toFixed(4);
    owner.effectsPaint ||= {};
    for (const [key, current] of Object.entries(paint)) {
      if (owner.effectsPaint[key] === current) continue;
      // Match the desktop's costly-shadow repaint thresholds. Springs still
      // advance each frame; a settled/explicitly snapped state paints exactly.
      const epsilon = key === "--text-shadow-blur-radius" ? .5
        : key === "--text-shadow-opacity" ? .01 : 0;
      if (!snap && value.moving && epsilon
          && Math.abs(parseFloat(owner.effectsPaint[key]) - parseFloat(current)) <= epsilon) continue;
      owner.effectsPaint[key] = current;
      element.style.setProperty(key, current);
    }
  }

  function updateLyrics(rawPosition, forceScroll = false) {
    if (!state.lines.length) return;
    const position = rawPosition - state.preferences.playbackOffset;
    const now = performance.now();
    const elapsed = state.lastEffectsTime === null ? 0 : (now - state.lastEffectsTime) / 1000;
    state.lastEffectsTime = now;
    if (!forceScroll && position === state.lastLyricPosition && !state.effectsMoving) return;
    const snapEffects = forceScroll || reduceMotion() || elapsed > .25
      || state.draggingSeek || Boolean(state.seekPreview);
    const dt = Math.max(0, Math.min(.05, elapsed));
    state.effectsMoving = false;
    state.lastLyricPosition = position;
    const activeIndex = model.findActiveLine(state.lines, position);
    const heldIndex = previewHeldLine(position, activeIndex);
    const paintIndex = heldIndex >= 0 ? heldIndex : activeIndex;
    const startIndex = Math.max(0, paintIndex - 5);
    const endIndex = Math.min(state.lines.length, Math.max(paintIndex + 7, 10));
    const inlineIndex = state.surface === "inline"
      ? model.findCaptionLine(state.lines, position, activeIndex) : -1;
    let captionGhost = null;
    if (state.surface === "inline" && state.captionIndex !== inlineIndex && !forceScroll) {
      captionGhost = snapshotCaption(state.lines[state.captionIndex]);
    }
    state.lines.forEach((line, index) => {
      // The desktop promotes its mounted lyric window to compositor layers.
      // Bound that hint here: the mobile DOM retains off-screen rows for seeking.
      const nearEffects = index >= startIndex && index < endIndex && Number.isFinite(line.start);
      if (line.nearEffects !== nearEffects) {
        line.nearEffects = nearEffects;
        line.element.classList.toggle("effects-near", nearEffects);
      }
      const visualState = model.lineVisualState(line, index, activeIndex, position);
      const active = visualState === "active";
      if (activeIndex >= 0) {
        const blur = active ? "0px" : `${Math.min(1.25 * Math.abs(index - activeIndex), 6.83125)}px`;
        if (line.paintBlur !== blur) {
          line.paintBlur = blur;
          line.element.style.setProperty("--line-blur", blur);
        }
      }
      if (line.previewHeld !== (index === heldIndex)) {
        line.previewHeld = index === heldIndex;
        line.element?.classList.toggle("preview-held", line.previewHeld);
      }
      if (line.visualState !== visualState) {
        line.visualState = visualState;
        line.element?.classList.toggle("active", active);
        line.element?.classList.toggle("sung", visualState === "sung");
        line.element?.classList.toggle("not-sung", visualState === "not-sung");
        if (line.kind === "lead" && line.element) {
          if (active) line.element.setAttribute("aria-current", "true");
          else line.element.removeAttribute("aria-current");
        }
        if (line.kind === "interlude") {
          line.dotEntrance?.cancel();
          line.dotEntrance = null;
          if (active && !reduceMotion() && !forceScroll && position < line.end - 500) {
            line.dotEntrance = line.element.querySelector(".dot-group").animate(
              [{ scale: "0" }, { scale: "1" }], { duration: 300, easing: "ease" }
            );
          }
        }
      }
      if (line.kind === "interlude") {
        const exiting = active && position > line.end - 500;
        if (line.dotExiting !== exiting) {
          line.dotExiting = exiting;
          if (exiting) { line.dotEntrance?.cancel(); line.dotEntrance = null; }
          line.element.classList.toggle("pre-hidden", exiting);
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
      // A brief untimed gap clears the actual active line, not the preview's
      // established scroll position. Only its first placement should snap.
      const firstLine = !state.hasPositionedLyrics;
      state.activeLine = activeIndex;
      if (state.followLyrics && activeIndex >= 0) scrollToLine(activeIndex, firstLine || forceScroll);
    } else if (forceScroll && state.followLyrics && activeIndex >= 0) {
      scrollToLine(activeIndex, true);
    }

    // Complete the held line's last token using its real provider timestamp,
    // even when a gap occurs beyond the initial token-rendering window.
    for (let index = startIndex; index < endIndex; index++) {
      const line = state.lines[index];
      if (line.kind === "lead" && !line.tokens.length) {
        const progress = model.tokenProgress(line, position);
        const gradient = `${(position < line.start ? -20 : progress * 100).toFixed(2)}%`;
        if (line.paintGradient !== gradient) {
          line.paintGradient = gradient;
          line.element.style.setProperty("--gradient-position", gradient);
        }
        if (Number.isFinite(line.start)) {
          paintEffects(line, line.element.querySelector(".line-text"), "line", progress, dt, snapEffects);
        }
      }
      if (line.kind === "interlude") {
        const dots = line.element?.querySelectorAll(".dot") || [];
        const segment = Math.max(1, (line.end - line.start - 550) / 3);
        [...dots].forEach((dot, dotIndex) => {
          const progress = model.clamp(
            (position - (line.start + dotIndex * segment)) / segment
          );
          const fill = progress.toFixed(3);
          if (dot.spicyFill !== fill) {
            dot.spicyFill = fill;
            dot.style.setProperty("--fill-number", fill);
          }
          paintEffects(dot, dot, "dot", progress, dt, snapEffects);
        });
      }
      (line.tokens || []).forEach((token) => {
        if (!token.element) return;
        const shouldPaint = state.surface !== "inline"
          || !token.element.parentElement?.hidden;
        const progress = model.tokenProgress(token, position);
        const fill = `${(progress * 100).toFixed(2)}%`;
        const gradient = `${(-20 + progress * 120).toFixed(2)}%`;
        if (shouldPaint && token.paintFill !== fill) {
          token.paintFill = fill;
          token.element.style.setProperty("--fill", fill);
          paintGlyphGradient(token.element, gradient);
        }
        const motionProgress = token.letters.length
          ? (position - token.start) / (token.end - token.start - 250) : progress;
        paintEffects(token, token.element, "word", motionProgress, dt, snapEffects, undefined, shouldPaint);
        token.letters.forEach((letter, letterIndex) => {
          const target = effects.letterTargets(letterIndex, token.letters.length, motionProgress);
          const letterGradient = `${target.gradient.toFixed(2)}%`;
          if (shouldPaint && letter.paintGradient !== letterGradient) {
            letter.paintGradient = letterGradient;
            paintGlyphGradient(letter.element, letterGradient);
          }
          paintEffects(letter, letter.element, "letter", 0, dt, snapEffects, target, shouldPaint);
        });
      });
    }
  }

  function scrollToLine(index, snap = false) {
    if (state.surface === "inline") return;
    const element = state.lines[index]?.element;
    if (!element) return;
    state.hasPositionedLyrics = true;
    const bounds = element.getBoundingClientRect();
    const target = dom.scroller.scrollTop + bounds.top
      - dom.scroller.getBoundingClientRect().top
      - (dom.scroller.clientHeight * .5 - 30) + bounds.height * .5;
    const immediate = snap || reduceMotion() || state.draggingSeek || Boolean(state.seekPreview);
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
    ambient.setEnabled(state.surface !== "inline" && state.preferences.dynamicBackground && !reduceMotion());
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

  let contentFrameKey = "";
  function applyContentFrame(frame) {
    const valid = state.surface === "card" && frame
      && [frame.x, frame.y, frame.width, frame.height].every(Number.isFinite)
      && frame.x >= 0 && frame.y >= 0 && frame.width > 0 && frame.height > 0;
    const key = valid ? JSON.stringify([frame.x, frame.y, frame.width, frame.height]) : "";
    if (key === contentFrameKey) return;
    contentFrameKey = key;
    for (const name of ["x", "y", "width", "height"]) {
      const property = `--card-content-${name}`;
      if (valid) document.documentElement.style.setProperty(property, `${frame[name]}px`);
      else document.documentElement.style.removeProperty(property);
    }
    resizeLyrics();
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
        applyContentFrame(null);
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
        document.body.classList.toggle("native-high-contrast", Boolean(payload.highContrast));
        applyPreferences();
        break;
      case "accessibility":
        state.nativeReduceMotion = Boolean(payload.reduceMotion);
        document.body.classList.toggle("native-reduce-motion", state.nativeReduceMotion);
        document.body.classList.toggle("native-high-contrast", Boolean(payload.highContrast));
        applyPreferences();
        state.lastLyricPosition = null;
        updateLyrics(positionNow(), true);
        break;
      case "layout":
        applyContentFrame(payload.contentFrame);
        break;
      case "session":
        applySession(payload);
        break;
      case "lyrics":
        if (!model.shouldAcceptLyrics(state.session, payload)) break;
        if (payload.state === "loading") showLoading();
        else if (payload.state === "ready") {
          // Timed-lyrics upgrade checks can return the unchanged line payload.
          // Keep its DOM, scroll glide and caption animation in that case.
          if (dom.lyricState.hidden && state.lines.length
              && state.lyricsTrackId === String(payload.trackId || "")
              && state.lyricsGeneration === String(payload.generation || "")
              && state.lyricsContentKey === JSON.stringify(payload.data)) break;
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
        ambient.syncMotion();
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
  function resizeLyrics() {
    cancelSeekDrag();
    stopEmbeddedMotion();
    cancelAnimationFrame(resizeFrame);
    resizeFrame = requestAnimationFrame(() => {
      fitWordGroups();
      updateLyrics(positionNow(), true);
    });
  }
  addEventListener("resize", resizeLyrics, { passive: true });
  // Native card slots and surface bootstrapping can reflow independently of
  // the window. Re-anchor after the actual viewport size has settled.
  if (typeof ResizeObserver === "function") {
    new ResizeObserver(resizeLyrics).observe(dom.scroller);
  }
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
    ambient.syncMotion();
  }, { passive: true });
  prefersReducedMotion.addEventListener?.("change", () => applyPreferences());

  applyPreferences();
  showLoading();
  requestAnimationFrame(animationFrame);
  post("ready", { rendererProtocolVersion: RENDERER_PROTOCOL_VERSION });
})();
