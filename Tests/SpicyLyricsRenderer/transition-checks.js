// Test-only public bridge and rendered-frame probes. Loaded in Chromium and
// in an isolated iOS WKWebView with the same production renderer resources.
window.runSpicyTransitionChecks = async function (phase) {
  const results = [];
  const frame = () => new Promise(requestAnimationFrame);
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  const paused = { isPlaying: false, isPaused: true, isAdvancing: false };
  // Historical v5 transition fixtures used a solid-color/pseudo-element paint.
  // Current desktop parity uses glyph gradients and line opacity instead. Keep
  // the same timing/hold guarantees and inspect the paint each renderer uses.
  const desktopPaint = Boolean(window.SpicyLyricsEffects);
  const brightGlyph = element => {
    if (!desktopPaint) return getComputedStyle(element).webkitTextFillColor === 'rgb(255, 255, 255)';
    const s = getComputedStyle(element), line = element.closest('.lyric-line');
    return Number(getComputedStyle(line).opacity)===1 && s.backgroundImage!=='none'
      && parseFloat(s.getPropertyValue('--gradient-position'))>=100;
  };
  const brightToken = token => desktopPaint
    ? [...(token.querySelector('.letter') ? token.querySelectorAll('.letter') : [token])].every(brightGlyph)
    : Number(getComputedStyle(token,'::after').opacity)===1;
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
  if (phase.startsWith('desktop-layout-')) {
    const surface=phase.slice('desktop-layout-'.length);
    bootstrap(surface,true);
    SpicyQA.lyrics.line.Content=Array.from({length:40},(_,i)=>({Type:'Vocal',Text:`Phrase ${i}`,StartTime:i*2,EndTime:i*2+2}));
    SpicyQA.scenario('line',{...paused,positionMs:40100,durationMs:80000});await document.fonts.ready;await wait(350);
    if (surface!=='inline') {
      const line=document.querySelector('.lead.active').getBoundingClientRect();
      const scroller=document.querySelector('#lyrics-scroller').getBoundingClientRect();
      const anchor=line.top+line.height/2-scroller.top;
      check(`${surface}: follow scrolling uses the desktop center-minus-30px anchor`,
        Math.abs(anchor-(scroller.height/2-30))<2,{anchor,expected:scroller.height/2-30});
    }
    SpicyQA.lyrics.karaoke.Content=[
      {Type:'Vocal',Lead:{StartTime:0,EndTime:2,Syllables:[{Text:'مرحبا',StartTime:0,EndTime:2}]}},
      {Type:'Vocal',OppositeAligned:true,Lead:{StartTime:2,EndTime:4,Syllables:[{Text:'שלום',StartTime:2,EndTime:4}]}}
    ];
    SpicyQA.scenario('karaoke',{...paused,positionMs:500});await frame();await frame();
    const rtl=[...document.querySelectorAll('.lead.rtl')];
    check(`${surface}: RTL shaping, sweep direction and duet sides follow the desktop layout`,
      rtl.length===2 && getComputedStyle(rtl[0]).textAlign==='right' && getComputedStyle(rtl[1]).textAlign==='left'
        && getComputedStyle(rtl[0].querySelector('.token')).getPropertyValue('--gradient-degrees').trim()==='-90deg'
        && !rtl.some(line=>line.querySelector('.letter')),
      rtl.map(line=>({text:line.textContent,align:getComputedStyle(line).textAlign})));
    SpicyQA.lyrics.karaoke.Content=[{Type:'Vocal',Lead:{StartTime:0,EndTime:2,Syllables:[
      {Text:'A',StartTime:0,EndTime:.3,IsPartOfWord:true},{Text:'ny',StartTime:.3,EndTime:.7},
      {Text:'time',StartTime:.7,EndTime:1.5}]}}];
    SpicyQA.scenario('karaoke',{...paused,positionMs:400});await frame();await frame();
    const joined=[...document.querySelector('.word-group').querySelectorAll('.token')];
    const origins=joined.map(token=>parseFloat(getComputedStyle(token).transformOrigin));
    check(`${surface}: joined syllables pivot at their shared edge without inserting spaces`,
      joined.length===2 && Math.abs(origins[0]-joined[0].offsetWidth)<1 && origins[1]===0
        && document.querySelector('.line-text').textContent==='Any time',origins);
    const gap=getComputedStyle(document.querySelector('#lyrics')).rowGap;
    check(`${surface}: row spacing does not retain a separate mobile-only gap`,gap==='0px',gap);
  }
  if (phase.startsWith('desktop-contrast-')) {
    const surface=phase.slice('desktop-contrast-'.length);
    SpicyQA.send('bootstrap',{surface,highContrast:true,reduceMotion:true,preferences:{fontSize:82}});
    SpicyQA.scenario('karaoke',{...paused,positionMs:6500});await frame();await frame();
    const lines=[...document.querySelectorAll('.lyric-line:not(.interlude)')];
    const glyphs=[...document.querySelectorAll('.token:not(.emphasis),.letter')];
    check(`${surface}: Increase Contrast restores clear readable quiet lyrics without changing sync`,
      lines.every(line=>getComputedStyle(line).opacity==='1' && parseFloat(getComputedStyle(line).getPropertyValue('--line-blur'))===0)
        && glyphs.every(glyph=>parseFloat(getComputedStyle(glyph).getPropertyValue('--gradient-alpha-end'))>=.85)
        && document.querySelector('#lyrics [aria-current]')?.textContent.includes('Any time'));
  }
  if (phase.startsWith('desktop-backdrop-')) {
    const surface = phase.slice('desktop-backdrop-'.length);
    bootstrap(surface,true);
    const veil = getComputedStyle(document.querySelector('.contrast-veil')).backgroundImage;
    const backdrop = getComputedStyle(document.querySelector('#artwork-backdrop'));
    check(`${surface}: the lighter cover veil preserves more artwork color at the existing blur`,
      veil.includes('0.62') && veil.includes('0.64') && veil.includes('0.78')
        && backdrop.filter.includes('blur(6px)'),{veil,filter:backdrop.filter});
  }
  if (phase === 'desktop-shuffle-fullscreen') {
    bootstrap('fullscreen',true);
    const smart = {...paused,shuffleMode:'smart',shuffleEnabled:true,smartShuffleAvailable:true};
    const ordinary = {...paused,shuffleMode:'shuffle',shuffleEnabled:true,smartShuffleAvailable:true};
    const off = {...paused,shuffleMode:'off',shuffleEnabled:false,smartShuffleAvailable:true};
    SpicyQA.scenario('karaoke',smart);await frame();
    const button=document.querySelector('#shuffle-button');
    button.click();let request=SpicyQA.messages.at(-1);
    SpicyQA.send('commandResult',{requestId:request.requestId,accepted:true});
    SpicyQA.observe(ordinary);await frame();
    const transient={mode:button.dataset.mode,label:button.getAttribute('aria-label'),pending:button.classList.contains('pending')};
    SpicyQA.observe(off);await frame();
    check('Smart Shuffle to Off does not flash the intermediate ordinary Shuffle state',
      transient.mode==='smart' && transient.pending && button.dataset.mode==='off' && !button.classList.contains('pending'),transient);
    SpicyQA.observe(smart);button.click();request=SpicyQA.messages.at(-1);
    SpicyQA.observe(ordinary);SpicyQA.send('commandResult',{requestId:request.requestId,accepted:false});await frame();
    check('a failed Smart Shuffle command reveals the actual latest native state',
      button.dataset.mode==='shuffle' && !button.classList.contains('pending'));
    SpicyQA.observe(smart);button.click();SpicyQA.observe(ordinary);await wait(3150);
    check('an unconfirmed Smart Shuffle command expires back to native truth',
      button.dataset.mode==='shuffle' && !button.classList.contains('pending'));
    SpicyQA.observe(smart);button.click();SpicyQA.scenario('next',off);await frame();
    check('changing songs clears the previous shuffle command presentation',
      button.dataset.mode==='off' && !button.classList.contains('pending'));
  }
  if (phase.startsWith('desktop-type-')) {
    const surface = phase.slice('desktop-type-'.length);
    bootstrap(surface);
    SpicyQA.lyrics.karaoke.Content = [{Type:'Vocal',Lead:{StartTime:0,EndTime:2,
      Syllables:[{Text:'Stay',StartTime:0,EndTime:.8},{Text:'close',StartTime:.8,EndTime:1.6}]},
      Background:[{StartTime:1,EndTime:2,Syllables:[{Text:'echo',StartTime:1,EndTime:1.8}]}]}];
    SpicyQA.scenario('karaoke',{...paused,positionMs:400});await document.fonts.ready;await wait(450);
    const lead = document.querySelector('.lead'), backing = document.querySelector('.background');
    const l = getComputedStyle(lead), b = getComputedStyle(backing), word = getComputedStyle(backing.querySelector('.token'));
    check(`${surface}: lyric font weight, spacing and backing size match desktop typography`,
      l.fontWeight==='700' && b.fontWeight==='600' && ['normal','0px'].includes(l.letterSpacing)
        && Math.abs(parseFloat(l.lineHeight)/parseFloat(l.fontSize)-1.1818181818)<.003
        && Math.abs(parseFloat(b.fontSize)/parseFloat(l.fontSize)-.75)<.003
        && /^-apple-system,/.test(l.fontFamily),
      {leadWeight:l.fontWeight,backingWeight:b.fontWeight,spacing:l.letterSpacing,lineHeight:l.lineHeight,
        leadSize:l.fontSize,backingSize:b.fontSize,family:l.fontFamily});
    check(`${surface}: upcoming backing vocals use desktop quiet shadow paint, with no early whitening`,
      Number(b.opacity)===.51 && word.backgroundImage==='none'
        && word.textShadow.includes('0.3') && parseFloat(b.getPropertyValue('--line-blur'))===1.25,
      {opacity:b.opacity,paint:word.backgroundImage,shadow:word.textShadow,blur:b.getPropertyValue('--line-blur')});
    SpicyQA.lyrics.line.Content=[{Type:'Vocal',Text:'Stay with me',StartTime:0,EndTime:4}];
    SpicyQA.scenario('line',{...paused,positionMs:2000});await wait(2300);
    const line = document.querySelector('.line-timed.active'), ls=getComputedStyle(line), text=getComputedStyle(line.querySelector('.line-text'));
    check(`${surface}: line-only lyrics have the desktop whole-line scale and glow`,
      Math.abs(parseFloat(ls.scale)-1.05)<.001 && parseFloat(text.getPropertyValue('--text-shadow-blur-radius'))===12
        && parseFloat(text.getPropertyValue('--text-shadow-opacity'))===.5,
      {scale:ls.scale,shadow:text.textShadow});
    SpicyQA.scenario('static',paused);await frame();await frame();
    const staticLine = document.querySelector('.lyric-line.static');
    const ss=getComputedStyle(staticLine);
    check(`${surface}: unsynced lyrics keep desktop medium white text without timed effects`,
      ss.fontWeight==='500' && ss.color==='rgb(255, 255, 255)' && Number(ss.opacity)===1
        && !staticLine.querySelector('.token') && staticLine.tagName==='DIV',
      {weight:ss.fontWeight,color:ss.color,opacity:ss.opacity});
  }
  if (phase.startsWith('desktop-emphasis-')) {
    const surface = phase.slice('desktop-emphasis-'.length);
    bootstrap(surface);
    SpicyQA.lyrics.karaoke.Content = [{Type:'Vocal',Lead:{StartTime:0,EndTime:3,
      Syllables:[{Text:'Hold',StartTime:0,EndTime:2.25},{Text:'on',StartTime:2.25,EndTime:2.9}]}}];
    SpicyQA.scenario('karaoke',{...paused,positionMs:750});
    await document.fonts.ready;await wait(2300);
    const word = document.querySelector('.lead .token');
    const letters = [...word.querySelectorAll('.letter')];
    const paint = letters.map(letter => {
      const s = getComputedStyle(letter);
      return { text:letter.textContent, gradient:parseFloat(s.getPropertyValue('--gradient-position')),
        scale:parseFloat(s.scale), y:new DOMMatrix(s.transform).m42/parseFloat(s.fontSize),
        glow:parseFloat(s.getPropertyValue('--text-shadow-opacity')) };
    });
    check(`${surface}: sustained syllables use the desktop letter sweep and proximity wave`,
      letters.length===4 && word.textContent==='Hold' && paint[0].gradient===100
        && Math.abs(paint[1].gradient-64.8528137423857)<.02 && paint[2].gradient===-20
        && paint[1].scale>paint[0].scale && paint[0].scale>paint[2].scale
        && paint[1].y<-.06 && paint[1].glow>=.99 && paint[2].glow===0,
      paint);
    SpicyQA.observe({...paused,positionMs:2000});await wait(2300);
    check(`${surface}: desktop emphasis finishes 250ms before the provider syllable end`,
      letters.length===4 && letters.every(letter=>parseFloat(getComputedStyle(letter).getPropertyValue('--gradient-position'))===100
        && Math.abs(parseFloat(getComputedStyle(letter).scale)-1)<.001));
    bootstrap(surface,true);SpicyQA.observe({...paused,positionMs:750});await frame();await frame();
    check(`${surface}: reduced-motion emphasized letters keep timing without a moving wave`,
      letters.length===4 && letters.every(letter=>['none','1'].includes(getComputedStyle(letter).scale)
        && new DOMMatrix(getComputedStyle(letter).transform).m42===0)
        && Math.abs(parseFloat(getComputedStyle(letters[1]).getPropertyValue('--gradient-position'))-64.8528137423857)<.02);
  }
  if (phase.startsWith('desktop-motion-')) {
    const surface=phase.slice('desktop-motion-'.length);
    bootstrap(surface);
    SpicyQA.lyrics.karaoke.Content=[{Type:'Vocal',Lead:{StartTime:0,EndTime:2,
      Syllables:[{Text:'Stay',StartTime:0,EndTime:.8},{Text:'close',StartTime:.8,EndTime:1.6}]}}];
    SpicyQA.scenario('karaoke',{...paused,positionMs:400});
    await document.fonts.ready;await wait(2300);
    const word=document.querySelector('.lead.active .token');const s=getComputedStyle(word);
    // Values captured from desktop cubic-spline@3.0.3 at progress .5.
    const scale=parseFloat(s.scale), matrix=new DOMMatrix(s.transform);
    const em=parseFloat(s.fontSize), y=matrix.m42/em;
    const blur=parseFloat(s.getPropertyValue('--text-shadow-blur-radius'));
    check(`${surface}: word scale, lift and glyph glow settle on the desktop spline`,
      Math.abs(scale-1.0485204081632653)<.002 && Math.abs(y+0.03534979423868313)<.002
        && Math.abs(blur-6.475308641975309)<.06 && s.textShadow!=='none',
      {scale,y,blur,textShadow:s.textShadow});
    bootstrap(surface,true);SpicyQA.observe({...paused,positionMs:500});await frame();await frame();
    const reduced=getComputedStyle(word);
    check(`${surface}: reduced motion removes lift and scale while retaining timed whitening`,
      ['none','1'].includes(reduced.scale) && new DOMMatrix(reduced.transform).m42===0
        && reduced.backgroundImage!=='none');
  }
  if (phase.startsWith('desktop-paint-')) {
    const surface = phase.slice('desktop-paint-'.length);
    bootstrap(surface,true);
    SpicyQA.lyrics.karaoke.Content = [{Type:'Vocal',Lead:{StartTime:0,EndTime:3,
      Syllables:[{Text:'Stay',StartTime:0,EndTime:.8},{Text:'with',StartTime:.8,EndTime:1.6},{Text:'me',StartTime:1.6,EndTime:2.4}]},
      Background:[{StartTime:0,EndTime:3,Syllables:[{Text:'Stay',StartTime:0,EndTime:.8},{Text:'close',StartTime:.8,EndTime:1.6}]}]
    }];
    SpicyQA.scenario('karaoke',{...paused,positionMs:400});
    await document.fonts.ready; await wait(300);
    const reference = document.createElement('span');
    reference.hidden=true;document.body.appendChild(reference);
    const gradient = value => {reference.style.backgroundImage=value;return getComputedStyle(reference).backgroundImage;};
    const lead = document.querySelector('.lead.active .token');
    const backing = document.querySelector('.background.active .token');
    const actual={lead:getComputedStyle(lead).backgroundImage,backing:getComputedStyle(backing).backgroundImage};
    const expected={
      lead:gradient('linear-gradient(90deg,rgba(255,255,255,.85) 40%,rgba(255,255,255,.5) 60%)'),
      backing:gradient('linear-gradient(90deg,rgba(255,255,255,.6) 40%,rgba(255,255,255,.3) 60%)')
    };
    check(`${surface}: lead and backing vocals use the desktop soft sweep and separate brightness`,
      actual.lead===expected.lead && actual.backing===expected.backing,{actual,expected});
    SpicyQA.observe({...paused,positionMs:0});await frame();await frame();
    const initial=getComputedStyle(lead).backgroundImage;
    check(`${surface}: desktop sweep starts before the glyph edge`,
      initial===gradient('linear-gradient(90deg,rgba(255,255,255,.85) -20%,rgba(255,255,255,.5) 0%)'),initial);
    SpicyQA.observe({...paused,positionMs:800});await frame();await frame();
    const finished=getComputedStyle(lead).backgroundImage;
    check(`${surface}: completed words retain desktop white without a clipped overlay`,
      finished===gradient('linear-gradient(90deg,rgba(255,255,255,.85) 100%,rgba(255,255,255,.5) 120%)')
        && ['none','normal'].includes(getComputedStyle(lead,'::after').content),finished);
    SpicyQA.lyrics.line.Content=[{Type:'Vocal',Text:'Stay with me',StartTime:0,EndTime:4}];
    SpicyQA.scenario('line',{...paused,positionMs:2000});await frame();await frame();
    const wholeLine = getComputedStyle(document.querySelector('.line-timed.active > .line-text')).backgroundImage;
    check(`${surface}: line-only lyrics use the desktop whole-line gradient, not invented word timing`,
      wholeLine===gradient('linear-gradient(180deg,rgba(255,255,255,.85) 50%,rgba(255,255,255,.35) 70%)')
        && !document.querySelector('.line-timed .token'),wholeLine);
    reference.remove();
  }
  if (phase.startsWith('desktop-interlude-')) {
    const surface = phase.slice('desktop-interlude-'.length);
    bootstrap(surface);
    SpicyQA.lyrics.line.Content = [
      {Type:'Vocal',Text:'Stay with me',StartTime:0,EndTime:2},
      {Type:'Vocal',Text:'Here we go',StartTime:8,EndTime:11}
    ];
    SpicyQA.scenario('line',{...paused,positionMs:1000});
    await document.fonts.ready; await wait(500); await waitForSteadyFrames();
    const row = document.querySelector('.interlude');
    const group = () => row.querySelector('.dot-group') || row;
    const before = row.getBoundingClientRect().height;
    SpicyQA.observe({...paused,positionMs:2100});
    const entering = [];
    for (const end = performance.now()+450; performance.now()<end;) {
      await frame(); const s=getComputedStyle(group());
      entering.push({scale:parseFloat(s.scale)||1,opacity:Number(getComputedStyle(row).opacity)});
    }
    const activeHeight = row.getBoundingClientRect().height;
    SpicyQA.observe({...paused,positionMs:7520});
    const exiting = [];
    for (const end = performance.now()+470; performance.now()<end;) {
      await frame(); exiting.push(parseFloat(getComputedStyle(group()).scale));
    }
    const exitedScale = getComputedStyle(group()).scale;
    SpicyQA.observe({...paused,positionMs:8100}); await wait(300);
    const after = row.getBoundingClientRect().height;
    check(`${surface}: pause dots enter, finish, exit and release their row`,
      before === 0 && activeHeight > 0
        && entering.some(s=>s.scale>.05&&s.scale<.95)
        && entering.at(-1).scale>=.99
        && exiting.some(s=>s>.05&&s<.95) && Number(exitedScale)===0 && after===0,
      {before,activeHeight,entering,exiting,exitedScale,after});
    SpicyQA.observe({...paused,positionMs:4000}); await wait(420);
    check(`${surface}: seeking back restores the pause dots`,
      row.getBoundingClientRect().height>0 && parseFloat(getComputedStyle(group()).scale)>=.99);
    bootstrap(surface,true); SpicyQA.observe({...paused,positionMs:7550}); await frame();await frame();
    check(`${surface}: reduced-motion pause exit is immediate`,
      Number(getComputedStyle(group()).scale)===0);
  }
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
    colors.push(desktopPaint ? getComputedStyle(document.querySelector('.line-timed.active')).opacity
      : getComputedStyle(document.querySelector('.line-timed.active .line-text')).webkitTextFillColor);
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
    await frame(); gapColors.push(brightGlyph(finishedPhrase));
  }
  check('preview stays white between a line ending and the next line starting',
    gapColors.length >= 4 && gapColors.every(Boolean)
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
      fill: token.style.getPropertyValue('--fill'), bright: brightToken(token)
    })));
  }
  check('word-timed preview completes and holds white through a gap beyond the first ten lines',
    wordGapFrames.length >= 4 && wordGapFrames.every(tokens => tokens.every(token =>
      token.fill === '100.00%' && token.bright)), wordGapFrames);
  check('holding a finished preview never starts future words or changes timing and scroll',
    [...nextWordLine.querySelectorAll('.token')].every(token => token.style.getPropertyValue('--fill') === '0.00%')
      && !document.querySelector('#lyrics [aria-current]') && scroller.scrollTop === wordScroll);
  SpicyQA.observe({ ...paused, positionMs: 26000, durationMs: 60000 });
  await wait(280);
  check('the old preview dims only once the next timed lyric takes over',
    [...wordLine.querySelectorAll('.token')].every(token => !brightToken(token))
      && nextWordLine.getAttribute('aria-current') === 'true'
      && [...nextWordLine.querySelectorAll('.token')].every(token => token.style.getPropertyValue('--fill') === '0.00%'));
  SpicyQA.observe({ ...paused, positionMs: 24900, durationMs: 60000 });
  await wait(280);
  check('rewinding into a held line restores real partial word progress',
    wordLine.getAttribute('aria-current') === 'true'
      && [...wordLine.querySelectorAll('.token')].some(token => {
        const fill = parseFloat(token.style.getPropertyValue('--fill'));
        return fill > 0 && fill < 100 && (desktopPaint ? getComputedStyle(token).backgroundImage!=='none'
          : Number(getComputedStyle(token, '::after').opacity) === 1);
      }));
  const seekHolds = [];
  for (const [positionMs, index] of [[21900,10], [31900,15]]) {
    SpicyQA.observe({ ...paused, positionMs, durationMs: 60000 });
    await wait(280);
    const leads = [...document.querySelectorAll('.lyric-line.lead')];
    const bright = leads.filter(line => [...line.querySelectorAll('.token')].every(token =>
      token.style.getPropertyValue('--fill') === '100.00%' && brightToken(token)));
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
  const noWhiteLead = () => leadText().every(text => !brightGlyph(text));
  check('preview does not pre-highlight lyrics before the first timestamp', noWhiteLead() && !document.querySelector('#lyrics [aria-current]'));
  bootstrap('card', true);
  SpicyQA.observe({ ...paused, positionMs: 2500, durationMs: 12000 });
  await wait(280);
  SpicyQA.observe({ ...paused, positionMs: 2900, durationMs: 12000 });
  await frame(); await frame();
  check('reduced-motion preview also stays white throughout a short gap',
    brightGlyph(leadText()[0])
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
    const textRGB = selector => {
      const element=document.querySelector(selector), style=getComputedStyle(element);
      if (!desktopPaint) return style.webkitTextFillColor.match(/[\d.]+/g).slice(0,3).map(Number);
      const line=element.closest('.lyric-line');
      const alpha=parseFloat(style.getPropertyValue(line.classList.contains('active') ? '--gradient-alpha' : '--gradient-alpha-end'));
      return Array(3).fill(255*alpha*Number(getComputedStyle(line).opacity));
    };
    const brightness = rgb => rgb.map(c => c / 255).map(c => c <= .04045 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4)
      .reduce((sum,c,i) => sum + c * [.2126,.7152,.0722][i], 0);
    const currentText = textRGB('.line-timed.active > .line-text');
    const futureText = textRGB('.line-timed.not-sung > .line-text');
    const highlightSeparation = (brightness(currentText) + .05) / (brightness(futureText) + .05);
    check('fullscreen unsung text is distinctly quieter than the white active lyric',
      currentText.every(c => Math.abs(c-(desktopPaint ? 255*.85 : 255))<.01) && highlightSeparation >= 3,
      {currentText, futureText, highlightSeparation});
    const coverBlur = Number(getComputedStyle(document.querySelector('#artwork-backdrop')).filter.match(/blur\(([\d.]+)px\)/)?.[1]);
    check('fullscreen cover retains a gentle blur with slightly more artwork definition',
      coverBlur >= 4 && coverBlur <= 8, {blurPx:coverBlur});
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
    const fullscreenFilter = getComputedStyle(backdrop).filter;
    const fullscreenVeil = getComputedStyle(document.querySelector('.contrast-veil')).backgroundImage;
    SpicyQA.send('bootstrap',{surface:'card',preferences:{dynamicBackground:true},reduceMotion:false});
    observe({isPlaying:true,isPaused:false,isAdvancing:true});
    for (const deadline = performance.now()+3000;performance.now()<deadline;) {
      await frame(); if(getComputedStyle(backdrop).backgroundImage.includes(artwork)) break;
    }
    check('preview uses the same current cover, blur and contrast veil as fullscreen',
      getComputedStyle(backdrop).display !== 'none'
        && getComputedStyle(backdrop).backgroundImage.includes(artwork)
        && getComputedStyle(backdrop).filter === fullscreenFilter
        && getComputedStyle(document.querySelector('.contrast-veil')).display !== 'none'
        && getComputedStyle(document.querySelector('.contrast-veil')).backgroundImage === fullscreenVeil);
    const previewStart = getComputedStyle(backdrop).transform;
    await wait(200);
    check('preview cover follows the same enabled playback motion',
      getComputedStyle(backdrop).animationPlayState === 'running'
        && getComputedStyle(backdrop).transform !== previewStart);
    SpicyQA.send('lifecycle',{state:'hidden'});
    await frame(); await frame();
    const coveredPreview = getComputedStyle(backdrop).transform;
    await wait(120);
    check('fullscreen-covered preview freezes its cover movement',
      getComputedStyle(backdrop).animationPlayState === 'paused'
        && getComputedStyle(backdrop).transform === coveredPreview);
    SpicyQA.send('lifecycle',{state:'visible'});
    observe(paused);
    await frame();
    check('paused preview keeps its current cover still and visible',
      getComputedStyle(backdrop).animationPlayState === 'paused'
        && getComputedStyle(backdrop).backgroundImage.includes(artwork));
    SpicyQA.send('bootstrap',{surface:'card',preferences:{dynamicBackground:true},reduceMotion:true});
    observe({isPlaying:true,isPaused:false,isAdvancing:true});
    await frame();
    check('reduced-motion preview keeps artwork without animation',
      getComputedStyle(backdrop).display !== 'none' && getComputedStyle(backdrop).animationName === 'none'
        && getComputedStyle(backdrop).backgroundImage.includes(artwork));
    SpicyQA.send('bootstrap',{surface:'card',preferences:{dynamicBackground:false},reduceMotion:false});
    await frame();
    check('preview respects the static-background preference',
      getComputedStyle(backdrop).animationPlayState === 'paused'
        && getComputedStyle(backdrop).backgroundImage.includes(artwork));
    SpicyQA.scenario('next',paused);
    await frame();
    check('preview clears the prior cover when the skipped-to song has none',
      getComputedStyle(backdrop).backgroundImage === 'none'
        && getComputedStyle(backdrop).backgroundColor === 'rgb(8, 8, 8)');
    SpicyQA.send('bootstrap',{surface:'inline',preferences:{dynamicBackground:true},reduceMotion:false});
    observe({isPlaying:true,isPaused:false,isAdvancing:true});
    await frame();
    check('above-title caption stays transparent without a cover layer',
      getComputedStyle(backdrop).display === 'none' && getComputedStyle(backdrop).backgroundImage === 'none'
        && getComputedStyle(document.querySelector('.contrast-veil')).display === 'none'
        && getComputedStyle(document.body).backgroundColor === 'rgba(0, 0, 0, 0)');
    bootstrap('fullscreen');
    SpicyQA.scenario('next',paused);
    await frame();
    check('new track with no cover clears the previous background',
      getComputedStyle(backdrop).backgroundImage === 'none');
  }
  if (phase === 'highlight') {
    const extraPaint = () => {
      const line = document.querySelector('.lyric-line.active');
      return [line, ...line.querySelectorAll('*')].flatMap(element =>
        [null, '::before', '::after'].flatMap(pseudo => {
          const style = getComputedStyle(element, pseudo);
          if (style.display === 'none' || (pseudo && ['none', 'normal', '""'].includes(style.content))) return [];
          // The PC uses un-clipped text shadows on actual glyphs. The reported
          // rectangle came from a clipped glowing duplicate, not that shadow.
          const properties = ['boxShadow','filter'];
          if (pseudo || style.clipPath!=='none'
              || !element.matches('.token:not(.emphasis),.letter,.line-text')) properties.push('textShadow');
          return properties.filter(property => style[property] !== 'none')
            .map(property => ({element:element.className,pseudo,property,value:style[property]}));
        }));
    };
    bootstrap('fullscreen', true);
    SpicyQA.lyrics.karaoke.Content = [
      {Type:'Vocal',Lead:{StartTime:0,EndTime:5,Syllables:[
        {Text:'Crossing',StartTime:0,EndTime:1}, {Text:'syllables',StartTime:1,EndTime:5}
      ]}}
    ];
    SpicyQA.scenario('karaoke',{...paused,positionMs:2500});
    await frame(); await frame();
    const syllablePaint = extraPaint();
    check('fullscreen syllable highlighting has no clipped duplicate or rectangular shadow',
      syllablePaint.length === 0, {extraPaint:syllablePaint});
    SpicyQA.scenario('line',{...paused,positionMs:1500});
    await frame(); await frame();
    const linePaint = extraPaint();
    check('fullscreen line highlighting has no clipped duplicate or rectangular shadow',
      linePaint.length === 0, {extraPaint:linePaint});
  }
  if (phase === 'card-layout') {
    bootstrap('card', true);
    SpicyQA.scenario('line',{...paused,positionMs:1500});
    await frame(); await frame();
    const lyric = document.querySelector('.lyric-line.active');
    SpicyQA.send('layout',{contentFrame:{x:16,y:56,width:328,height:320}});
    await frame(); await frame();
    const stage = document.querySelector('.stage').getBoundingClientRect();
    const backdrop = document.querySelector('#artwork-backdrop').getBoundingClientRect();
    check('full-card background keeps lyrics inside the native content rectangle',
      Math.abs(stage.x-16)<1 && Math.abs(stage.y-56)<1 && Math.abs(stage.width-328)<1 && Math.abs(stage.height-320)<1
        && backdrop.left <= 0 && backdrop.top <= 0 && backdrop.right >= innerWidth && backdrop.bottom >= innerHeight,
      {stage:stage.toJSON(),backdrop:backdrop.toJSON()});
    SpicyQA.send('layout',{contentFrame:{x:16,y:56,width:328,height:320}});
    await frame();
    check('repeated native card layout preserves the active lyric DOM',
      document.querySelector('.lyric-line.active') === lyric);
    SpicyQA.send('layout',{contentFrame:null});
    await frame(); await frame();
    const reset = document.querySelector('.stage').getBoundingClientRect();
    check('standalone preview falls back to its whole available content area',
      reset.x === 0 && reset.y === 0 && Math.abs(reset.width-innerWidth)<1 && Math.abs(reset.height-innerHeight)<1,
      {stage:reset.toJSON()});
  }
  return results;
};
