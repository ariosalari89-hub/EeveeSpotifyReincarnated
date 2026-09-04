window.SPICY_TEST_FIXTURES = {
  syllable: {
    Type: "Syllable",
    StartTime: 5.5,
    Content: [
      { Type: "Vocal", Lead: { StartTime: 5.5, EndTime: 10.2, Syllables: [
        { Text: "Streetlights", StartTime: 5.5, EndTime: 6.7 },
        { Text: "paint", StartTime: 6.8, EndTime: 7.5 },
        { Text: "the", StartTime: 7.55, EndTime: 8.05 },
        { Text: "windows", StartTime: 8.1, EndTime: 9.25 },
        { Text: "gold", StartTime: 9.3, EndTime: 10.2 }
      ]}},
      { Type: "Vocal", Lead: { StartTime: 11, EndTime: 15.7, Syllables: [
        { Text: "Every", StartTime: 11, EndTime: 11.8 },
        { Text: "secret", StartTime: 11.85, EndTime: 12.8 },
        { Text: "we", StartTime: 12.9, EndTime: 13.4 },
        { Text: "never", StartTime: 13.5, EndTime: 14.35 },
        { Text: "told", StartTime: 14.4, EndTime: 15.7 }
      ]}},
      { Type: "Vocal", OppositeAligned: true, Lead: { StartTime: 16.6, EndTime: 21.4, Syllables: [
        { Text: "Meet", StartTime: 16.6, EndTime: 17.2 },
        { Text: "me", StartTime: 17.25, EndTime: 17.8 },
        { Text: "after", StartTime: 17.85, EndTime: 19 },
        { Text: "mid", IsPartOfWord: true, StartTime: 19.1, EndTime: 19.8 },
        { Text: "night", StartTime: 19.8, EndTime: 21.4 }
      ]}},
      { Type: "Vocal", Lead: { StartTime: 22, EndTime: 25.4, Syllables: [
        { Text: "A", IsPartOfWord: true, StartTime: 22, EndTime: 22.25 },
        { Text: "ny", StartTime: 22.25, EndTime: 22.8 },
        { Text: "time", StartTime: 22.9, EndTime: 23.5 },
        { Text: "I", StartTime: 23.6, EndTime: 23.9 },
        { Text: "count", StartTime: 24, EndTime: 24.6 },
        { Text: "sheep", StartTime: 24.7, EndTime: 25.4 }
      ]}}
    ]
  },
  line: {
    Type: "Line",
    StartTime: 5,
    Content: [
      { Type: "Vocal", Text: "First line timing", StartTime: 5, EndTime: 8 },
      { Type: "Vocal", Text: "Second line timing", StartTime: 8.2, EndTime: 12 }
    ]
  },
  lineMilliseconds: {
    Type: "Line",
    TimeUnit: "milliseconds",
    StartTime: 5000,
    Content: [
      { Type: "Vocal", Text: "Millisecond opening line", StartTime: 5000, EndTime: 8000 },
      { Type: "Vocal", Text: "Millisecond second line", StartTime: 8200, EndTime: 12000 }
    ]
  },
  desktopLongSyllable: {
    Type: "Syllable",
    id: "desktop-parity-fixture",
    source: "aml",
    StartTime: 10.1,
    EndTime: 207.0,
    Content: [
      { Type: "Vocal", Lead: { StartTime: 30.0, EndTime: 34.2, Syllables: [
        { Text: "Every", StartTime: 30.0, EndTime: 30.8 },
        { Text: "word", StartTime: 30.85, EndTime: 31.6 },
        { Text: "keeps", StartTime: 31.65, EndTime: 32.4 },
        { Text: "its", StartTime: 32.45, EndTime: 32.9 },
        { Text: "timing", StartTime: 32.95, EndTime: 34.2 }
      ]}},
      { Type: "Vocal", Lead: { StartTime: 198.0, EndTime: 207.0, Syllables: [
        { Text: "Long", StartTime: 198.0, EndTime: 200.0 },
        { Text: "songs", StartTime: 200.1, EndTime: 202.0 },
        { Text: "stay", StartTime: 202.1, EndTime: 204.0 },
        { Text: "synced", StartTime: 204.1, EndTime: 207.0 }
      ]}}
    ]
  }
};
