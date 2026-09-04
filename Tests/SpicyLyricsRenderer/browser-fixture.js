(() => {
  "use strict";

  const messages = [];
  let generation = 1;
  let sequence = 0;
  let trackId = "qa-karaoke";

  window.webkit = {
    messageHandlers: {
      eevee: {
        postMessage(message) {
          messages.push(JSON.parse(JSON.stringify(message)));
        }
      }
    }
  };

  const tracks = {
    karaoke: {
      id: "qa-karaoke",
      title: "Any Time",
      artist: "Deterministic Test",
      album: "Playback State Machine",
      artwork: "",
      dominantColor: "4f244c"
    },
    line: {
      id: "qa-line",
      title: "Line by Line",
      artist: "Deterministic Test",
      album: "Playback State Machine",
      artwork: "",
      dominantColor: "233b58"
    },
    static: {
      id: "qa-static",
      title: "Read Along",
      artist: "Deterministic Test",
      album: "Playback State Machine",
      artwork: "",
      dominantColor: "69442d"
    },
    next: {
      id: "qa-next",
      title: "Next Song",
      artist: "Deterministic Test",
      album: "Playback State Machine",
      artwork: "",
      dominantColor: "245640"
    }
  };

  const lyrics = {
    karaoke: {
      Type: "Syllable",
      StartTime: 0.5,
      HasTransliterations: true,
      Content: [
        {
          Type: "Vocal",
          Lead: {
            StartTime: 0.5,
            EndTime: 3,
            Syllables: [
              { Text: "Start", StartTime: 0.5, EndTime: 1.5 },
              { Text: "clean", StartTime: 1.6, EndTime: 3 }
            ]
          }
        },
        {
          Type: "Vocal",
          OppositeAligned: true,
          Lead: {
            StartTime: 3.2,
            EndTime: 6,
            Syllables: [
              { Text: "Duet", StartTime: 3.2, EndTime: 4.1 },
              { Text: "answer", StartTime: 4.2, EndTime: 6 }
            ]
          }
        },
        {
          Type: "Vocal",
          TranslatedText: "Any time, don't stop",
          Lead: {
            StartTime: 6,
            EndTime: 10,
            Syllables: [
              { Text: "A", IsPartOfWord: true, StartTime: 6, EndTime: 6.4 },
              { Text: "ny", StartTime: 6.4, EndTime: 6.9 },
              { Text: "time", StartTime: 7, EndTime: 7.6 },
              { Text: ",", StartTime: 7.6, EndTime: 7.7 },
              { Text: "don", IsPartOfWord: true, StartTime: 7.8, EndTime: 8.35 },
              { Text: "’", IsPartOfWord: true, StartTime: 8.35, EndTime: 8.42 },
              { Text: "t", StartTime: 8.42, EndTime: 8.65 },
              { Text: "stop", StartTime: 8.8, EndTime: 10 }
            ]
          },
          Background: [
            {
              StartTime: 7.2,
              EndTime: 9.3,
              Syllables: [
                { Text: "مرحبا", StartTime: 7.2, EndTime: 9.3 }
              ]
            }
          ]
        },
        {
          Type: "Vocal",
          Lead: {
            StartTime: 13.5,
            EndTime: 16,
            Syllables: [
              { Text: "After", StartTime: 13.5, EndTime: 14.7 },
              { Text: "interlude", StartTime: 14.8, EndTime: 16 }
            ]
          }
        }
      ]
    },
    line: {
      Type: "Line",
      StartTime: 1,
      Content: [
        { Type: "Vocal", Text: "First line is finished", StartTime: 1, EndTime: 4 },
        { Type: "Vocal", Text: "This line is active", StartTime: 4, EndTime: 8 },
        { Type: "Vocal", Text: "This line comes next", StartTime: 8.2, EndTime: 12 },
        { Type: "Vocal", Text: "Opposite aligned response", StartTime: 12, EndTime: 16, OppositeAligned: true }
      ]
    },
    static: {
      Type: "Static",
      Lines: [
        { Text: "Static lyrics remain readable." },
        { Text: "They never pretend to be synchronized." },
        { Text: "No line is painted as current." },
        { Text: "The transport remains fully available." }
      ]
    },
    next: {
      Type: "Line",
      Content: [
        { Type: "Vocal", Text: "The next song replaced everything", StartTime: 0, EndTime: 5 },
        { Type: "Vocal", Text: "Old callbacks cannot return", StartTime: 5, EndTime: 10 }
      ]
    }
  };

  function send(type, payload) {
    window.SpicyNative.receive({ type, payload });
  }

  function sendSession(overrides = {}) {
    const selectedTrack = overrides.track || tracks.karaoke;
    trackId = overrides.trackId || selectedTrack.id;
    generation = Number(overrides.generation ?? generation);
    sequence = Number(overrides.sequence ?? (sequence + 1));
    const isPlaying = overrides.isPlaying ?? true;
    const isPaused = overrides.isPaused ?? !isPlaying;
    const payload = {
      generation: String(generation),
      sequence: String(sequence),
      trackId,
      playbackId: overrides.playbackId || `playback-${generation}`,
      sessionId: "qa-session",
      positionMs: overrides.positionMs ?? 6500,
      durationMs: overrides.durationMs ?? 30000,
      playbackRate: overrides.playbackRate ?? 1,
      isPlaying,
      isPaused,
      isLoading: overrides.isLoading ?? false,
      isBuffering: overrides.isBuffering ?? false,
      isAdvancing: overrides.isAdvancing ?? (isPlaying && !isPaused),
      requiresFreshObservation: overrides.requiresFreshObservation ?? false,
      shuffleEnabled: overrides.shuffleEnabled ?? false,
      shuffleMode: overrides.shuffleMode || (overrides.shuffleEnabled ? "shuffle" : "off"),
      smartShuffleAvailable: overrides.smartShuffleAvailable ?? false,
      repeatMode: overrides.repeatMode || "off",
      canSeek: overrides.canSeek ?? true,
      canPause: overrides.canPause ?? true,
      canResume: overrides.canResume ?? true,
      canGoPrevious: overrides.canGoPrevious ?? true,
      canGoNext: overrides.canGoNext ?? true,
      canToggleShuffle: overrides.canToggleShuffle ?? true,
      canToggleRepeatContext: overrides.canToggleRepeatContext ?? true,
      canToggleRepeatTrack: overrides.canToggleRepeatTrack ?? true,
      track: { ...selectedTrack, id: trackId }
    };
    send("session", payload);
    return payload;
  }

  function sendLyrics(kind, options = {}) {
    const selected = lyrics[kind];
    send("lyrics", {
      state: "ready",
      trackId: options.trackId || trackId,
      generation: String(options.generation ?? generation),
      data: selected
    });
  }

  function scenario(kind, options = {}) {
    const selectedTrack = tracks[kind];
    generation = Number(options.generation ?? (generation + 1));
    sequence = 0;
    sendSession({
      ...options,
      generation,
      track: selectedTrack,
      trackId: selectedTrack.id
    });
    sendLyrics(kind, { generation, trackId: selectedTrack.id });
  }

  function observe(options = {}) {
    return sendSession({ ...options, generation, trackId, track: {
      ...(Object.values(tracks).find((candidate) => candidate.id === trackId) || tracks.karaoke),
      id: trackId
    }});
  }

  function inspect() {
    const active = document.querySelector(".lyric-line.active");
    return {
      title: document.querySelector("#title")?.textContent || "",
      timing: document.querySelector("#lyrics")?.dataset.timing || "",
      positionMs: Number(document.querySelector("#seek")?.value || 0),
      activeText: active?.textContent?.trim() || "",
      lineCount: document.querySelectorAll(".lyric-line").length,
      pendingCount: document.querySelectorAll(".pending").length,
      shufflePressed: document.querySelector("#shuffle-button")?.getAttribute("aria-pressed"),
      repeatMode: document.querySelector("#repeat-button")?.dataset.mode,
      playLabel: document.querySelector("#play-button")?.getAttribute("aria-label"),
      settingsOpen: !document.querySelector("#settings-sheet")?.hidden,
      messages: messages.slice()
    };
  }

  window.SpicyQA = {
    messages,
    tracks,
    lyrics,
    send,
    sendSession,
    sendLyrics,
    scenario,
    observe,
    inspect,
    clearMessages() { messages.length = 0; }
  };

  scenario("karaoke", { generation: 1, positionMs: 7500 });
  return "Spicy Lyrics browser fixture installed";
})();
