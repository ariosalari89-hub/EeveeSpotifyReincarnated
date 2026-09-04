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
        { Text: "mid", StartTime: 19.1, EndTime: 19.8 },
        { Text: "night", IsPartOfWord: true, StartTime: 19.8, EndTime: 21.4 }
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
  }
};
