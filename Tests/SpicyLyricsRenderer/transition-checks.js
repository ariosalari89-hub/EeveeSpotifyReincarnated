// Test-only public bridge and rendered-frame probes. Loaded in Chromium and
// in an isolated iOS WKWebView with the same production renderer resources.
window.runSpicyTransitionChecks = async function (phase) {
  const results = [];
  const frame = () => new Promise(requestAnimationFrame);
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  const paused = { isPlaying: false, isPaused: true, isAdvancing: false };
  const check = (name, pass, detail) => results.push({ name, pass, detail });
  const waitForSteadyFrames = async () => {
    // A cold simulator can still be migrating system data after boot. Require
    // an observable starting cadence, not an arbitrary extra sleep or a lower
    // intermediate-frame threshold. Keep actual sample times in the result.
    let previous = await frame();
    const deltas = [];
    for (const deadline = performance.now() + 5000; performance.now() < deadline;) {
      const now = await frame(), delta = now - previous;
      previous = now;
      if (!document.hidden && delta > 0 && delta <= 40) deltas.push(delta);
      else deltas.length = 0;
      if (deltas.length >= 6) return deltas;
    }
    throw new Error('No six-frame starting cadence within 5 seconds for motion sampling');
  };
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
  await waitForSteadyFrames();
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
  const gapColors = [];
  const finishedPhrase = document.querySelectorAll('.line-timed > .line-text')[1];
  for (const deadline = performance.now() + 280; performance.now() < deadline;) {
    await frame(); gapColors.push(getComputedStyle(finishedPhrase).webkitTextFillColor);
  }
  check('preview stays white between a line ending and the next line starting',
    gapColors.length >= 4 && gapColors.every(color => color === 'rgb(255, 255, 255)')
      && !document.querySelector('#lyrics [aria-current]'), gapColors);
  const gapCadence = await waitForSteadyFrames();
  const gapStart = scroller.scrollTop;
  SpicyQA.observe({ ...paused, positionMs: 4100, durationMs: 60000 });
  const gapPositions = [], gapFrameTimes = [], gapStarted = performance.now();
  for (const deadline = performance.now() + 450; performance.now() < deadline;) {
    await frame(); gapPositions.push(scroller.scrollTop); gapFrameTimes.push(performance.now() - gapStarted);
  }
  const gapEnd = gapPositions.at(-1);
  check('preview glides into the next line after a short silent gap',
    gapEnd > gapStart + 10
      && new Set(gapPositions.filter(p => p > gapStart + 1 && p < gapEnd - 1)).size >= 4,
    { start: gapStart, positions: gapPositions, frameTimes: gapFrameTimes, cadenceBeforeMs: gapCadence });
  await waitForSteadyFrames();
  const refreshSession = SpicyQA.observe({ ...paused, positionMs: 6100, durationMs: 60000 });
  await wait(50);
  const refreshStart = scroller.scrollTop;
  SpicyQA.send('lyrics', { state:'ready', trackId:refreshSession.trackId,
    generation:refreshSession.generation, data:JSON.parse(JSON.stringify(SpicyQA.lyrics.line)) });
  const refreshPositions = [];
  for (const deadline = performance.now() + 450; performance.now() < deadline;) {
    await frame(); refreshPositions.push(scroller.scrollTop);
  }
  const refreshEnd = refreshPositions.at(-1);
  check('an unchanged lyrics refresh preserves the in-flight preview glide',
    refreshEnd > refreshStart + 10
      && new Set(refreshPositions.filter(p => p > refreshStart + 1 && p < refreshEnd - 1)).size >= 4,
    { start:refreshStart, positions:refreshPositions });
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

  SpicyQA.lyrics.karaoke.Content = Array.from({ length: 30 }, (_, i) => ({ Type: 'Vocal',
    Lead: { StartTime: i * 2, EndTime: i * 2 + 1.7, Syllables: [
      { Text: `Word ${i} `, StartTime: i * 2, EndTime: i * 2 + .8 },
      { Text: 'finishes', StartTime: i * 2 + .8, EndTime: i * 2 + 1.7 }
    ] }
  }));
  SpicyQA.scenario('karaoke', { ...paused, positionMs: 25400, durationMs: 60000 });
  await wait(350);
  const wordLine = document.querySelectorAll('.lyric-line.lead')[12];
  const nextWordLine = document.querySelectorAll('.lyric-line.lead')[13];
  const wordScroll = scroller.scrollTop;
  SpicyQA.observe({ ...paused, positionMs: 25900, durationMs: 60000 });
  const wordGapFrames = [];
  for (const deadline = performance.now() + 280; performance.now() < deadline;) {
    await frame();
    wordGapFrames.push([...wordLine.querySelectorAll('.token')].map(token => ({
      fill: token.style.getPropertyValue('--fill'), opacity: Number(getComputedStyle(token, '::after').opacity)
    })));
  }
  check('word-timed preview completes and holds white through a gap beyond the first ten lines',
    wordGapFrames.length >= 4 && wordGapFrames.every(tokens => tokens.every(token =>
      token.fill === '100.00%' && token.opacity === 1)), wordGapFrames);
  check('holding a finished preview never starts future words or changes timing and scroll',
    [...nextWordLine.querySelectorAll('.token')].every(token => token.style.getPropertyValue('--fill') === '0.00%')
      && !document.querySelector('#lyrics [aria-current]') && scroller.scrollTop === wordScroll);
  SpicyQA.observe({ ...paused, positionMs: 26000, durationMs: 60000 });
  await wait(280);
  check('the old preview dims only once the next timed lyric takes over',
    [...wordLine.querySelectorAll('.token')].every(token => Number(getComputedStyle(token, '::after').opacity) === 0)
      && nextWordLine.getAttribute('aria-current') === 'true'
      && [...nextWordLine.querySelectorAll('.token')].every(token => token.style.getPropertyValue('--fill') === '0.00%'));
  SpicyQA.observe({ ...paused, positionMs: 24900, durationMs: 60000 });
  await wait(280);
  check('rewinding into a held line restores real partial word progress',
    wordLine.getAttribute('aria-current') === 'true'
      && [...wordLine.querySelectorAll('.token')].some(token => {
        const fill = parseFloat(token.style.getPropertyValue('--fill'));
        return fill > 0 && fill < 100 && Number(getComputedStyle(token, '::after').opacity) === 1;
      }));
  const seekHolds = [];
  for (const [positionMs, index] of [[21900,10], [31900,15]]) {
    SpicyQA.observe({ ...paused, positionMs, durationMs: 60000 });
    await wait(280);
    const leads = [...document.querySelectorAll('.lyric-line.lead')];
    const bright = leads.filter(line => [...line.querySelectorAll('.token')].every(token =>
      token.style.getPropertyValue('--fill') === '100.00%' && Number(getComputedStyle(token, '::after').opacity) === 1));
    seekHolds.push(bright.length === 1 && bright[0] === leads[index] && !document.querySelector('#lyrics [aria-current]'));
  }
  check('backward and forward gap observations hold only the correct preview line', seekHolds.every(Boolean), seekHolds);

  SpicyQA.lyrics.line.Content = [
    {Type:'Vocal',Text:'First timed phrase',StartTime:1,EndTime:2.7},
    {Type:'Vocal',Text:'Second timed phrase',StartTime:3,EndTime:4.7},
    {Type:'Vocal',Text:'After the instrumental',StartTime:8,EndTime:9.7}
  ];
  SpicyQA.scenario('line', { ...paused, positionMs: 500, durationMs: 12000 });
  await wait(280);
  const leadText = () => [...document.querySelectorAll('.line-timed > .line-text')];
  const noWhiteLead = () => leadText().every(text => getComputedStyle(text).webkitTextFillColor !== 'rgb(255, 255, 255)');
  check('preview does not pre-highlight lyrics before the first timestamp', noWhiteLead() && !document.querySelector('#lyrics [aria-current]'));
  bootstrap('card', true);
  SpicyQA.observe({ ...paused, positionMs: 2500, durationMs: 12000 });
  await wait(280);
  SpicyQA.observe({ ...paused, positionMs: 2900, durationMs: 12000 });
  await frame(); await frame();
  check('reduced-motion preview also stays white throughout a short gap',
    getComputedStyle(leadText()[0]).webkitTextFillColor === 'rgb(255, 255, 255)'
      && !document.querySelector('#lyrics [aria-current]'));
  SpicyQA.observe({ ...paused, positionMs: 6000, durationMs: 12000 });
  await wait(280);
  check('instrumental interludes do not retain an obsolete white preview',
    noWhiteLead() && Boolean(document.querySelector('.interlude.active')));
  SpicyQA.observe({ ...paused, positionMs: 10000, durationMs: 12000 });
  await wait(280);
  check('preview does not keep the final lyric white after its timing ends', noWhiteLead() && !document.querySelector('#lyrics [aria-current]'));
  SpicyQA.observe({ ...paused, positionMs: 2900, durationMs: 12000 });
  await wait(280);
  SpicyQA.scenario('next', { ...paused, positionMs: 500 });
  await wait(280);
  check('changing songs clears the previous preview hold and lyric text',
    !document.querySelector('.preview-held') && !document.querySelector('#lyrics').textContent.includes('First timed phrase'));
  SpicyQA.scenario('static', { ...paused, positionMs: 500 });
  await frame(); await frame();
  check('static lyrics never acquire timed preview holds',
    document.querySelector('#lyrics').dataset.timing === 'static'
      && !document.querySelector('.preview-held') && !document.querySelector('#lyrics [aria-current]'));
  bootstrap('fullscreen');
  SpicyQA.scenario('line', { ...paused, positionMs: 2500, durationMs: 12000 });
  await wait(280);
  SpicyQA.observe({ ...paused, positionMs: 2900, durationMs: 12000 });
  await wait(280);
  check('fullscreen retains its original timed highlight behavior',
    noWhiteLead() && !document.querySelector('.preview-held') && !document.querySelector('#lyrics [aria-current]'));
  bootstrap('inline');
  SpicyQA.observe({ ...paused, positionMs: 2900, durationMs: 12000 });
  await frame(); await frame();
  check('inline caption retains its own phrase handoff without preview styling',
    document.querySelector('.inline-visible')?.textContent === 'First timed phrase' && !document.querySelector('.preview-held'));
  }
  if (phase === 'background') {
    bootstrap('fullscreen');
    SpicyQA.lyrics.line.Content = [
      {Type:'Vocal',Text:'Current fullscreen phrase',StartTime:0,EndTime:2},
      {Type:'Vocal',Text:'Upcoming fullscreen phrase',StartTime:2,EndTime:4}
    ];
    SpicyQA.scenario('line', { ...paused, positionMs: 1500 });
    await wait(280);
    const textRGB = selector => getComputedStyle(document.querySelector(selector)).webkitTextFillColor.match(/[\d.]+/g).slice(0,3).map(Number);
    const brightness = rgb => rgb.map(c => c / 255).map(c => c <= .04045 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4)
      .reduce((sum,c,i) => sum + c * [.2126,.7152,.0722][i], 0);
    const currentText = textRGB('.line-timed.active > .line-text');
    const futureText = textRGB('.line-timed.not-sung > .line-text');
    const highlightSeparation = (brightness(currentText) + .05) / (brightness(futureText) + .05);
    check('fullscreen unsung text is distinctly quieter than the white active lyric',
      currentText.every(c => c === 255) && highlightSeparation >= 2,
      {currentText, futureText, highlightSeparation});
    const coverBlur = Number(getComputedStyle(document.querySelector('#artwork-backdrop')).filter.match(/blur\(([\d.]+)px\)/)?.[1]);
    check('fullscreen cover retains a gentle blur with slightly more artwork definition',
      coverBlur >= 24 && coverBlur <= 30, {blurPx:coverBlur});
    const canvas = document.createElement('canvas'); canvas.width = canvas.height = 16;
    const context = canvas.getContext('2d'); context.fillStyle = '#466a91';context.fillRect(0,0,16,16);
    const artwork = canvas.toDataURL();
    const track = {...SpicyQA.tracks.line,artwork};
    const observe = options => SpicyQA.sendSession({positionMs:2500,durationMs:60000,track,...options});
    SpicyQA.send('bootstrap',{surface:'fullscreen',preferences:{dynamicBackground:true},reduceMotion:false});
    observe({isPlaying:true,isPaused:false,isAdvancing:true});
    const backdrop = document.querySelector('#artwork-backdrop');
    for (const deadline = performance.now()+3000;performance.now()<deadline;) {
      await frame(); if(getComputedStyle(backdrop).backgroundImage.includes(artwork)) break;
    }
    check('blur background loads the current cover at full strength',
      getComputedStyle(backdrop).backgroundImage.includes(artwork)
        && Number(getComputedStyle(backdrop).opacity) >= .9
        && getComputedStyle(backdrop).filter.includes('blur('));
    const backgroundCadence = await waitForSteadyFrames();
    const movingStart = getComputedStyle(backdrop).transform;
    const movingSamples = [], movingStarted = performance.now();
    for (const deadline = movingStarted + 500; performance.now() < deadline;) {
      await frame();
      const style = getComputedStyle(backdrop);
      movingSamples.push({ elapsedMs: performance.now() - movingStarted,
        transform: style.transform, playState: style.animationPlayState });
    }
    check('enabled background moves slowly during playback',
      getComputedStyle(backdrop).animationPlayState === 'running'
        && movingSamples.some(sample => sample.transform !== movingStart),
      { start: movingStart, samples: movingSamples, cadenceBeforeMs: backgroundCadence,
        className: backdrop.className, animationName: getComputedStyle(backdrop).animationName,
        hidden: document.hidden });
    SpicyQA.send('lifecycle',{state:'hidden'});
    await frame();await frame();
    const hiddenTransform = getComputedStyle(backdrop).transform;
    await wait(120);
    check('hidden cover background freezes without residual animation',
      getComputedStyle(backdrop).animationPlayState === 'paused'
        && getComputedStyle(backdrop).transform === hiddenTransform);
    SpicyQA.send('lifecycle',{state:'visible'});
    observe(paused);
    await frame();
    check('paused playback keeps the blur still and visible',
      getComputedStyle(backdrop).animationPlayState === 'paused'
        && getComputedStyle(backdrop).backgroundImage.includes(artwork));
    SpicyQA.send('bootstrap',{surface:'fullscreen',preferences:{dynamicBackground:true},reduceMotion:true});
    observe({isPlaying:true,isPaused:false,isAdvancing:true});
    await frame();
    check('reduced motion disables cover movement without dimming the blur',
      getComputedStyle(backdrop).animationName === 'none' && Number(getComputedStyle(backdrop).opacity) >= .9);
    SpicyQA.send('bootstrap',{surface:'fullscreen',preferences:{dynamicBackground:false},reduceMotion:false});
    await frame();
    check('dynamic-background preference can leave a static blurred cover',
      getComputedStyle(backdrop).animationPlayState === 'paused'
        && getComputedStyle(backdrop).backgroundImage.includes(artwork));
    SpicyQA.scenario('next',paused);
    await frame();
    check('new track with no cover clears the previous background',
      getComputedStyle(backdrop).backgroundImage === 'none');
  }
  return results;
};
