// Test-only public bridge and rendered-frame probes. Loaded in Chromium and
// in an isolated iOS WKWebView with the same production renderer resources.
window.runSpicyTransitionChecks = async function (phase) {
  const results = [];
  const frame = () => new Promise(requestAnimationFrame);
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  const paused = { isPlaying: false, isPaused: true, isAdvancing: false };
  const check = (name, pass, detail) => results.push({ name, pass, detail });
  const waitForPaintedCaption = async text => {
    // A timer is not evidence that a newly attached/resized WKWebView has
    // painted its starting phrase. Establish that precondition in real frames.
    await document.fonts.ready;
    let stableFrames = 0;
    for (const deadline = performance.now() + 3000; performance.now() < deadline;) {
      await frame();
      const line = document.querySelector('#lyrics .inline-visible');
      const rect = line?.getBoundingClientRect();
      stableFrames = !document.hidden && innerHeight === 52 && line?.textContent === text
        && rect.height > 0 && rect.top >= 0 && rect.bottom <= innerHeight ? stableFrames + 1 : 0;
      if (stableFrames >= 6) return;
    }
    throw new Error('Caption did not paint its stable initial phrase before transition sampling');
  };
  const bootstrap = (surface, reduceMotion = false) => SpicyQA.send('bootstrap', {
    surface, reduceMotion, preferences: { fontSize: 100, playbackOffset: 0, dynamicBackground: false }
  });
  if (phase === 'inline') {
  bootstrap('inline');
  SpicyQA.lyrics.line.Content = [
    { Type: 'Vocal', Text: 'First phrase', StartTime: 0, EndTime: 2 },
    { Type: 'Vocal', Text: 'Second phrase', StartTime: 2, EndTime: 4 },
    { Type: 'Vocal', Text: 'Third phrase', StartTime: 4, EndTime: 6 }
  ];
  SpicyQA.scenario('line', { ...paused, positionMs: 1500 });
  await waitForPaintedCaption('First phrase');
  SpicyQA.observe({ ...paused, positionMs: 2100 });
  const opacity = [], frameTimes = [];
  const transitionStarted = performance.now();
  let overlappingCaptionFrames = 0;
  for (const deadline = performance.now() + 400; performance.now() < deadline;) {
    await frame();
    const line = document.querySelector('#lyrics .inline-visible');
    frameTimes.push(performance.now() - transitionStarted);
    opacity.push(Number(getComputedStyle(line).opacity));
    const outgoing = document.querySelector('.caption-outgoing');
    if (outgoing) {
      const a = line.getBoundingClientRect(), b = outgoing.getBoundingClientRect();
      if (Math.min(a.bottom,b.bottom) - Math.max(a.top,b.top) > .5) overlappingCaptionFrames++;
    }
  }
  check('caption changes blend through real intermediate frames',
    opacity.some(o => o > .05 && o < .95) && opacity.at(-1) > .99, { opacity, frameTimes });
  check('incoming and outgoing caption text never superimpose', overlappingCaptionFrames === 0, overlappingCaptionFrames);
  check('caption has one semantic current phrase after its transition',
    document.querySelectorAll('#lyrics .inline-visible').length === 1
      && document.querySelector('#lyrics .inline-visible').textContent === 'Second phrase'
      && document.querySelectorAll('.caption-outgoing').length === 0);
  SpicyQA.observe({ ...paused, positionMs: 4100 });
  await frame();
  SpicyQA.observe({ ...paused, positionMs: 500 });
  await wait(300);
  check('rapid caption replacement leaves no stale outgoing layer',
    document.querySelector('#lyrics .inline-visible').textContent === 'First phrase'
      && !document.querySelector('.caption-outgoing'));
  bootstrap('inline', true);
  SpicyQA.observe({ ...paused, positionMs: 2100 });
  await frame();
  check('reduced-motion caption is immediate with no outgoing animation',
    document.querySelector('#lyrics .inline-visible').textContent === 'Second phrase'
      && Number(getComputedStyle(document.querySelector('#lyrics .inline-visible')).opacity) === 1
      && !document.querySelector('.caption-outgoing'));

  bootstrap('inline');
  SpicyQA.lyrics.karaoke.Content = [{ Type: 'Vocal', Lead: { StartTime: 0, EndTime: 20,
    Syllables: Array.from({length: 20}, (_,i) => ({Text: `Pageword${i} `,StartTime:i,EndTime:i+1})) }}];
  SpicyQA.scenario('karaoke', { ...paused, positionMs: 500 });
  await wait(350);
  SpicyQA.observe({ ...paused, positionMs: 15500 });
  const pageOpacity = [];
  for (const deadline = performance.now() + 350; performance.now() < deadline;) {
    await frame(); pageOpacity.push(Number(getComputedStyle(document.querySelector('#lyrics .inline-visible')).opacity));
  }
  const currentWord = [...document.querySelectorAll('#lyrics .inline-visible .token')].find(e=>e.textContent==='Pageword15 ');
  check('caption word-boundary pages blend and keep the actual timed word visible',
    pageOpacity.some(o=>o>.05&&o<.95) && currentWord.getClientRects().length>0 && !document.querySelector('.caption-outgoing'),pageOpacity);
  }

  if (phase === 'card') {
  bootstrap('card');
  SpicyQA.lyrics.line.Content = Array.from({ length: 30 }, (_, i) => ({
    Type: 'Vocal', Text: `Preview phrase ${i}`, StartTime: i * 2, EndTime: i * 2 + 2
  }));
  SpicyQA.scenario('line', { ...paused, positionMs: 2100, durationMs: 60000 });
  await wait(700);
  const scroller = document.querySelector('#lyrics-scroller');
  const start = scroller.scrollTop;
  SpicyQA.observe({ ...paused, positionMs: 4100, durationMs: 60000 });
  const positions = [], colors = [];
  for (const deadline = performance.now() + 450; performance.now() < deadline;) {
    await frame();
    positions.push(scroller.scrollTop);
    colors.push(getComputedStyle(document.querySelector('.line-timed.active .line-text')).webkitTextFillColor);
  }
  const end = positions.at(-1);
  const intermediate = positions.filter(p => p > start + 1 && p < end - 1);
  check('preview scroll has multiple intermediate positions, not a teleport',
    end > start + 10 && new Set(intermediate).size >= 4
      && positions.every((p, i) => !i || p >= positions[i - 1] - 1), { start, positions });
  check('line-timed preview highlight fades rather than switching instantly',
    new Set(colors).size >= 4, colors);
  SpicyQA.lyrics.line.Content.forEach(line => { line.EndTime -= .3; });
  SpicyQA.scenario('line', { ...paused, positionMs: 2500, durationMs: 60000 });
  await wait(400);
  SpicyQA.observe({ ...paused, positionMs: 3900, durationMs: 60000 });
  await frame(); await frame();
  const gapStart = scroller.scrollTop;
  SpicyQA.observe({ ...paused, positionMs: 4100, durationMs: 60000 });
  const gapPositions = [];
  for (const deadline = performance.now() + 450; performance.now() < deadline;) {
    await frame(); gapPositions.push(scroller.scrollTop);
  }
  const gapEnd = gapPositions.at(-1);
  check('preview glides into the next line after a short silent gap',
    gapEnd > gapStart + 10
      && new Set(gapPositions.filter(p => p > gapStart + 1 && p < gapEnd - 1)).size >= 4,
    { start: gapStart, positions: gapPositions });
  bootstrap('card', true);
  SpicyQA.observe({ ...paused, positionMs: 10100, durationMs: 60000 });
  await frame(); await frame();
  const reduced = scroller.scrollTop;
  await wait(100);
  check('reduced-motion preview reaches destination without residual scrolling',
    Math.abs(scroller.scrollTop - reduced) < 1);
  bootstrap('card');
  SpicyQA.observe({ ...paused, positionMs: 12100, durationMs: 60000 });
  await frame(); await frame();
  SpicyQA.send('lifecycle', { state: 'hidden' });
  const hidden = scroller.scrollTop;
  await wait(180);
  check('hidden preview does no leftover scrolling', Math.abs(scroller.scrollTop - hidden) < 1);
  SpicyQA.send('lifecycle', { state: 'resuming' });
  SpicyQA.observe({ ...paused, positionMs: 20100, durationMs: 60000 });
  SpicyQA.send('lifecycle', { state: 'visible' });
  await wait(500);
  const active = document.querySelector('.active').getBoundingClientRect();
  check('returning preview follows the fresh lyric', active.top >= 0 && active.bottom <= innerHeight);
  }
  return results;
};
