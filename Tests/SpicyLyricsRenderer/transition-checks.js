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
    const alpha = Number(s.getPropertyValue('--gradient-alpha'));
    const solidWhite = alpha===1 ? 'rgb(255, 255, 255)' : `rgba(255, 255, 255, ${alpha})`;
    return Number(getComputedStyle(line).opacity)===1
      && (s.backgroundImage!=='none' || s.webkitTextFillColor===solidWhite)
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
      stableFrames = !document.hidden && innerHeight === 52
        && line?.textContent.replace(/\s+/g,' ').trim() === text.trim()
        && rect.height > 0 && rect.top >= 0 && rect.bottom <= innerHeight ? stableFrames + 1 : 0;
      if (stableFrames >= 6) return;
    }
    throw new Error('Caption did not paint its stable initial phrase before transition sampling');
  };
  const bootstrap = (surface, reduceMotion = false) => SpicyQA.send('bootstrap', {
    surface, reduceMotion, preferences: { fontSize: 100, playbackOffset: 0, dynamicBackground: false }
  });
  if (phase === 'background-lifecycle') {
    const playing={isPlaying:true,isPaused:false,isAdvancing:true};
    const preferences={romanized:false,translations:true,dynamicBackground:true,backgroundStyle:'artwork',backgroundSpeed:175,fontSize:100,playbackOffset:0};
    SpicyQA.send('bootstrap',{surface:'fullscreen',reduceMotion:false,preferences});
    SpicyQA.scenario('karaoke',playing);
    const canvas=document.createElement('canvas');canvas.width=canvas.height=32;
    const context=canvas.getContext('2d');context.fillStyle='#365b87';context.fillRect(0,0,32,32);
    context.fillStyle='#b96b40';context.fillRect(16,0,16,32);
    const track={...SpicyQA.tracks.karaoke,artwork:canvas.toDataURL()};
    const observe=options=>SpicyQA.sendSession({track,...options});observe(playing);
    const backdrop=document.querySelector('#artwork-backdrop');
    for(const deadline=performance.now()+3000;performance.now()<deadline;){await frame();if(backdrop.classList.contains('is-animated'))break;}
    const originalLine=document.querySelector('#lyrics .lyric-line');
    const moves=async()=>{await frame();await frame();const start=getComputedStyle(backdrop).transform;await wait(160);await frame();return start!==getComputedStyle(backdrop).transform;};
    for(const style of ['artwork','gradient']) {
      const pref={...preferences,backgroundStyle:style};SpicyQA.send('preferences',pref);
      const started=await moves();observe(paused);const pausedStill=!(await moves());
      observe(playing);const resumed=await moves();SpicyQA.send('lifecycle',{state:'hidden'});const hiddenStill=!(await moves());
      SpicyQA.send('preferences',{...pref,dynamicBackground:false});SpicyQA.send('lifecycle',{state:'visible'});
      const offStill=!(await moves());SpicyQA.send('preferences',pref);const reopened=await moves();
      SpicyQA.send('accessibility',{reduceMotion:true});const reducedStill=!(await moves());
      const reducedDisabled=document.querySelector('#background-speed').disabled;
      const reason=document.querySelector('#background-motion-note');
      const explained=Boolean(reason && !reason.hidden && reason.textContent==='Reduced Motion is on');
      SpicyQA.send('accessibility',{reduceMotion:false});const restored=await moves();
      check(`${style}: saved motion survives pause, hide, live settings and Reduced Motion changes`,
        started && pausedStill && resumed && hiddenStill && offStill && reopened && reducedStill && reducedDisabled && explained && restored
          && reason.hidden && !document.querySelector('#background-speed').disabled
          && document.querySelector('#background-speed').value==='175' && document.querySelector('#lyrics .lyric-line')===originalLine,
        {started,pausedStill,resumed,hiddenStill,offStill,reopened,reducedStill,reducedDisabled,explained,restored});
    }
  }
  if (phase === 'background-motion-perception') {
    SpicyQA.send('bootstrap',{surface:'fullscreen',reduceMotion:false,preferences:{dynamicBackground:true,backgroundSpeed:100}});
    SpicyQA.scenario('karaoke',{isPlaying:true,isPaused:false,isAdvancing:true});
    const canvas=document.createElement('canvas');canvas.width=canvas.height=32;
    const context=canvas.getContext('2d');context.fillStyle='#365b87';context.fillRect(0,0,32,32);
    context.fillStyle='#b96b40';context.fillRect(16,0,16,16);context.fillRect(0,16,16,16);
    SpicyQA.sendSession({track:{...SpicyQA.tracks.karaoke,artwork:canvas.toDataURL()},isPlaying:true,isPaused:false,isAdvancing:true});
    const backdrop=document.querySelector('#artwork-backdrop');
    for(const deadline=performance.now()+3000;performance.now()<deadline;){await frame();if(backdrop.classList.contains('is-animated'))break;}
    await waitForSteadyFrames();
    const matrix=()=>new DOMMatrixReadOnly(getComputedStyle(backdrop).transform);
    const start=matrix();await wait(1000);await frame();const end=matrix();
    const movement=Math.hypot(end.e-start.e,end.f-start.f);
    check('default cover motion is perceptible within one second of opening lyrics',movement>=2,{movement,start:start.toString(),end:end.toString()});
  }
  if (phase === 'gradient-network') {
    SpicyQA.send('bootstrap',{surface:'fullscreen',reduceMotion:true,preferences:{backgroundStyle:'gradient'}});
    SpicyQA.scenario('karaoke',paused);
    const backdrop=document.querySelector('#artwork-backdrop'),origin=SpicyQA.artworkOrigin;
    if(!origin)throw new Error('Artwork network fixture origin is required');
    SpicyQA.sendSession({...paused,track:{...SpicyQA.tracks.karaoke,artwork:origin+'/cors.svg',dominantColor:''}});
    for(const deadline=performance.now()+1800;performance.now()<deadline;) {await frame();if(getComputedStyle(backdrop).backgroundImage.includes('204, 51, 51'))break;}
    const sampled=getComputedStyle(backdrop).backgroundImage;
    SpicyQA.sendSession({...paused,track:{...SpicyQA.tracks.karaoke,artwork:origin+'/opaque.svg',dominantColor:'2a7e91'}});
    await wait(250);await frame();const fallback=getComputedStyle(backdrop).backgroundImage;
    document.querySelector('#settings-button').click();await frame();
    const picker=document.querySelector('#background-style');picker.value='artwork';picker.dispatchEvent(new Event('change',{bubbles:true}));
    for(const deadline=performance.now()+1800;performance.now()<deadline;) {await frame();if(getComputedStyle(backdrop).backgroundImage.includes('/opaque.svg'))break;}
    const cover=getComputedStyle(backdrop).backgroundImage;
    check('remote cover pixels yield a palette while CORS-denied artwork remains available as cover art',
      sampled.includes('204, 51, 51') && sampled.includes('51, 102, 204')
        && fallback.includes('42, 126, 145') && cover.includes('/opaque.svg'),{sampled,fallback,cover});
    document.querySelector('#settings-close').click();
  }
  if (phase === 'gradient-recovery') {
    SpicyQA.send('bootstrap',{surface:'fullscreen',reduceMotion:true,preferences:{backgroundStyle:'gradient',dynamicBackground:true}});
    SpicyQA.scenario('karaoke',paused);
    const backdrop=document.querySelector('#artwork-backdrop');
    const send=track=>SpicyQA.sendSession({...paused,track:{...SpicyQA.tracks.karaoke,...track}});
    send({artwork:'',dominantColor:'#2a7e91'});await frame();
    const fallback=getComputedStyle(backdrop).backgroundImage;
    const canvas=document.createElement('canvas');canvas.width=canvas.height=16;
    const ctx=canvas.getContext('2d');ctx.fillStyle='#cc3333';ctx.fillRect(0,0,16,16);
    send({artwork:canvas.toDataURL(),dominantColor:'cc3333'});
    send({artwork:'',dominantColor:'c48832'});await wait(150);await frame();
    const next=getComputedStyle(backdrop).backgroundImage;
    send({artwork:'',dominantColor:'invalid'});await frame();
    const missing=getComputedStyle(backdrop).backgroundImage;
    check('gradient uses current native cover color when pixels are unavailable and rejects stale artwork',
      fallback.includes('42, 126, 145') && next.includes('196, 136, 50')
        && !next.includes('204, 51, 51') && missing==='none', {fallback,next,missing});
  }
  if (phase === 'background-speed') {
    SpicyQA.send('bootstrap',{surface:'fullscreen',reduceMotion:false,preferences:{dynamicBackground:true}});
    SpicyQA.scenario('karaoke',{isPlaying:true,isPaused:false,isAdvancing:true});
    const canvas=document.createElement('canvas');canvas.width=canvas.height=16;
    const ctx=canvas.getContext('2d');ctx.fillStyle='#cc3333';ctx.fillRect(0,0,8,16);
    ctx.fillStyle='#3366cc';ctx.fillRect(8,0,8,16);
    SpicyQA.sendSession({track:{...SpicyQA.tracks.karaoke,artwork:canvas.toDataURL()},isPlaying:true,isPaused:false,isAdvancing:true});
    const backdrop=document.querySelector('#artwork-backdrop');
    for(const deadline=performance.now()+3000;performance.now()<deadline;) {await frame();if(backdrop.classList.contains('is-animated'))break;}
    document.querySelector('#settings-button').click();await frame();
    const slider=document.querySelector('#background-speed');
    if(!slider){check('background speed slider controls both styles without restarting motion',false,{reason:'Speed slider is absent'});return results;}
    const initial={min:slider.min,max:slider.max,value:slider.value};
    const samples=[];
    for(const style of ['artwork','gradient']) {
      const picker=document.querySelector('#background-style');picker.value=style;picker.dispatchEvent(new Event('change',{bubbles:true}));await frame();
      for(const speed of [25,200]) {
        const animation=backdrop.getAnimations()[0],before=Number(animation.currentTime),beforeRate=animation.playbackRate,
          beforeTimeline=Number(document.timeline.currentTime);
        slider.value=String(speed);slider.dispatchEvent(new Event('input',{bubbles:true}));
        slider.dispatchEvent(new Event('change',{bubbles:true}));
        const immediateAdvance=Number(animation.currentTime)-before,
          immediateElapsed=Number(document.timeline.currentTime)-beforeTimeline;
        await frame();
        const start=performance.now(),time=Number(animation.currentTime),paint=getComputedStyle(backdrop).transform,
          elapsed=Number(document.timeline.currentTime)-beforeTimeline;
        await wait(280);await frame();
        samples.push({style,speed,beforeRate,elapsed,before,after:time,advance:time-before,immediateAdvance,immediateElapsed,
          rate:(Number(animation.currentTime)-time)/(performance.now()-start),jump:Math.abs(time-before),moving:paint!==getComputedStyle(backdrop).transform});
      }
    }
    const request=SpicyQA.messages.at(-1),output=document.querySelector('#background-speed-output')?.textContent;
    const toggle=document.querySelector('#background-toggle');toggle.checked=false;toggle.dispatchEvent(new Event('change',{bubbles:true}));await frame();await frame();
    const frozen=getComputedStyle(backdrop).transform;await wait(180);await frame();
    check('background speed slider controls both styles without restarting motion',
      initial.min==='25' && initial.max==='200' && initial.value==='100'
        // A late frame at 2x legitimately advances over 150 animation ms.
        // Bound continuity by actual timeline elapsed at the old/new rates,
        // including the synchronous change, instead of assuming frame cadence.
        && samples.every(s=>s.moving
          && [[s.advance,s.elapsed],[s.immediateAdvance,s.immediateElapsed]].every(([advance,elapsed])=>
            advance>=elapsed*Math.min(s.beforeRate,s.speed/100)-20
              && advance<=elapsed*Math.max(s.beforeRate,s.speed/100)+20)
          && (s.speed===25?s.rate>.15 && s.rate<.4:s.rate>1.7 && s.rate<2.3))
        && request.type==='setPreference' && request.key==='backgroundSpeed' && request.value===200
        && output==='2×' && slider.disabled && getComputedStyle(backdrop).transform===frozen,
      {initial,samples,request,output,disabled:slider.disabled,frozen});
    document.querySelector('#settings-close').click();
  }
  if (phase === 'background-style') {
    bootstrap('fullscreen',true);
    SpicyQA.scenario('karaoke',paused);
    const canvas=document.createElement('canvas');canvas.width=canvas.height=64;
    const ctx=canvas.getContext('2d');ctx.fillStyle='#cc3333';ctx.fillRect(0,0,32,64);
    ctx.fillStyle='#3366cc';ctx.fillRect(32,0,32,64);
    const artwork=canvas.toDataURL(), track={...SpicyQA.tracks.karaoke,artwork};
    SpicyQA.sendSession({...paused,track,positionMs:7400});
    const backdrop=document.querySelector('#artwork-backdrop');
    for(const deadline=performance.now()+3000;performance.now()<deadline;) {
      await frame();if(getComputedStyle(backdrop).backgroundImage.includes(artwork))break;
    }
    document.querySelector('#settings-button').click();await frame();
    const picker=document.querySelector('#background-style');
    if(!picker){check('lyric settings offer cover art and a cover-derived gradient',false,{reason:'Background style control is absent'});return results;}
    const defaultStyle=picker.value;
    picker.value='gradient';picker.dispatchEvent(new Event('change',{bubbles:true}));await frame();
    const gradient=getComputedStyle(backdrop).backgroundImage;
    const request=SpicyQA.messages.at(-1);
    check('lyric settings offer cover art and a cover-derived gradient',
      defaultStyle==='artwork' && picker.options.length===2
        && gradient.includes('radial-gradient') && !gradient.includes('url(')
        && gradient.includes('204, 51, 51') && gradient.includes('51, 102, 204')
        && request.type==='setPreference' && request.key==='backgroundStyle' && request.value==='gradient',
      {defaultStyle,gradient,request});
    document.querySelector('#settings-close').click();
  }
  if (phase === 'shuffle-availability') {
    bootstrap('fullscreen', true);
    const smart = {...paused,shuffleMode:'smart',shuffleEnabled:true,smartShuffleAvailable:true,canToggleShuffle:true};
    const off = {...smart,shuffleMode:'off',shuffleEnabled:false};
    SpicyQA.scenario('karaoke',smart);await frame();
    const button=document.querySelector('#shuffle-button');
    button.click();const request=SpicyQA.messages.at(-1);
    SpicyQA.send('commandResult',{requestId:request.requestId,accepted:true});
    const frames=[];
    for(const observation of [{...smart,canToggleShuffle:false},{...off,canToggleShuffle:false},off]) {
      SpicyQA.observe(observation);
      for(let i=0;i<4;i++) {await frame();frames.push({mode:button.dataset.mode,
        opacity:Number(getComputedStyle(button).opacity),disabled:button.disabled,
        busy:button.getAttribute('aria-busy')});}
    }
    for(const deadline=performance.now()+500;button.classList.contains('pending') && performance.now()<deadline;) await frame();
    check('temporary native shuffle unavailability never dims the in-flight button',
      frames.every(s=>s.opacity>=.85) && frames.slice(0,8).every(s=>s.disabled && s.busy==='true')
        && button.dataset.mode==='off' && !button.disabled && !button.classList.contains('pending'),{frames});
  }
  if (phase === 'shuffle-settlement') {
    bootstrap('fullscreen',true);
    const smart={...paused,shuffleMode:'smart',shuffleEnabled:true,smartShuffleAvailable:true};
    const off={...smart,shuffleMode:'off',shuffleEnabled:false};
    const ordinary={...smart,shuffleMode:'shuffle'};
    SpicyQA.scenario('karaoke',smart);await frame();await frame();
    const button=document.querySelector('#shuffle-button');
    button.click();const request=SpicyQA.messages.at(-1);
    SpicyQA.send('commandResult',{requestId:request.requestId,accepted:true});
    // Two native publications may run before WebKit paints either one. An
    // early target observation must not release an unfinished transition.
    SpicyQA.observe(off);SpicyQA.observe(ordinary);
    const frames=[];
    for(let i=0;i<4;i++){await frame();frames.push({mode:button.dataset.mode,busy:button.getAttribute('aria-busy')});}
    SpicyQA.observe(off);await wait(160);SpicyQA.observe(off);
    for(let i=0;i<4;i++){await frame();frames.push({mode:button.dataset.mode,busy:button.getAttribute('aria-busy')});}
    check('an early Off publication cannot expose intermediate ordinary Shuffle before final Off',
      frames.slice(0,4).every(s=>s.mode==='smart' && s.busy==='true')
        && frames.every(s=>s.mode!=='shuffle') && frames.at(-1).mode==='off'
        && !button.classList.contains('pending'),{frames});
  }
  if (phase.startsWith('desktop-layout-')) {
    const surface=phase.slice('desktop-layout-'.length);
    bootstrap(surface,true);
    SpicyQA.lyrics.line.Content=Array.from({length:40},(_,i)=>({Type:'Vocal',Text:`Phrase ${i}`,StartTime:i*2,EndTime:i*2+2}));
    SpicyQA.scenario('line',{...paused,positionMs:40100,durationMs:80000});await document.fonts.ready;
    // Retain the original layout-settlement interval: surface and viewport
    // resizing can finish after the first current-lyric frames. The additional
    // paint precondition handles cold native startup, not a shorter deadline.
    await wait(350);
    let layoutReadyFrames=0;
    for(const deadline=performance.now()+3000;performance.now()<deadline && layoutReadyFrames<2;) {
      await frame();
      layoutReadyFrames=document.querySelector('#lyrics [aria-current]')?.textContent==='Phrase 20'
        && Number(document.querySelector('#seek').value)===40100 ? layoutReadyFrames+1 : 0;
    }
    if(layoutReadyFrames<2)throw new Error('Current lyric did not paint before measuring the layout anchor');
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
    if(surface!=='inline') {
      const inset=rtl[0].offsetWidth*.05;
      const leadInset=parseFloat(getComputedStyle(rtl[0]).paddingLeft);
      const duetInset=parseFloat(getComputedStyle(rtl[1]).paddingRight);
      check(`${surface}: duet voices keep the desktop five-percent opposite-side inset`,
        Math.abs(leadInset-inset)<1 && Math.abs(duetInset-inset)<1,{leadInset,duetInset,expected:inset});
    }
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
    // Every phase also runs consecutively in one WKWebView. Own this fixture
    // instead of depending on the default data before the layout phase edits it.
    SpicyQA.lyrics.karaoke.Content=[
      {Type:'Vocal',Lead:{StartTime:6,EndTime:9,Syllables:[{Text:'Any time',StartTime:6,EndTime:9}]}},
      {Type:'Vocal',Lead:{StartTime:10,EndTime:13,Syllables:[{Text:'Next phrase',StartTime:10,EndTime:13}]},
        Background:[{StartTime:10,EndTime:13,Syllables:[{Text:'Quiet backing',StartTime:10,EndTime:13}]}]}
    ];
    SpicyQA.scenario('karaoke',{...paused,positionMs:6500});await frame();await frame();
    const lines=[...document.querySelectorAll('.lyric-line:not(.interlude)')];
    const glyphs=[...document.querySelectorAll('.token:not(.emphasis),.letter')];
    check(`${surface}: Increase Contrast restores clear readable quiet lyrics without changing sync`,
      lines.every(line=>getComputedStyle(line).opacity==='1' && parseFloat(getComputedStyle(line).getPropertyValue('--line-blur'))===0)
        && glyphs.every(glyph=>parseFloat(getComputedStyle(glyph).getPropertyValue('--gradient-alpha-end'))>=.85)
        && document.querySelector('#lyrics [aria-current]')?.textContent.includes('Any time'),
      {current:document.querySelector('#lyrics [aria-current]')?.textContent,
        lines:lines.map(line=>({opacity:getComputedStyle(line).opacity,blur:getComputedStyle(line).getPropertyValue('--line-blur')})),
        alpha: glyphs.map(glyph=>getComputedStyle(glyph).getPropertyValue('--gradient-alpha-end'))});
    const retainedLine=document.querySelector('#lyrics [aria-current]');
    SpicyQA.send('accessibility',{highContrast:false,reduceMotion:true});await wait(250);
    const quiet=document.querySelector('.background .token');
    check(`${surface}: a live accessibility change restores PC dimming without replacing the lyric`,
      retainedLine===document.querySelector('#lyrics [aria-current]')
        && Math.abs(parseFloat(getComputedStyle(quiet).getPropertyValue('--gradient-alpha-end'))-.3)<.001
        && getComputedStyle(quiet.closest('.lyric-line')).opacity==='0.51');
  }
  if (phase.startsWith('desktop-backdrop-')) {
    const surface = phase.slice('desktop-backdrop-'.length);
    bootstrap(surface,true);
    const veilStyle = getComputedStyle(document.querySelector('.contrast-veil'));
    const veil = veilStyle.backgroundImage;
    const backdrop = getComputedStyle(document.querySelector('#artwork-backdrop'));
    check(`${surface}: cover keeps a clear central veil without an opaque base or heavy blur`,
      veilStyle.backgroundColor==='rgba(0, 0, 0, 0)'
        && veil.includes('0.1) 36%') && backdrop.filter.includes('blur(2px)'),
      {veil,base:veilStyle.backgroundColor,filter:backdrop.filter});
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
    SpicyQA.observe(off);await wait(160);SpicyQA.observe(off);await frame();
    check('Smart Shuffle to Off does not flash the intermediate ordinary Shuffle state',
      transient.mode==='smart' && transient.pending && button.dataset.mode==='off' && !button.classList.contains('pending'),transient);
    SpicyQA.observe(smart);button.click();request=SpicyQA.messages.at(-1);
    const count=SpicyQA.messages.filter(m=>m.type==='toggleShuffle').length;
    button.click();
    SpicyQA.observe(off);
    const beforeAcknowledgement=[];
    for(const deadline=performance.now()+100;performance.now()<deadline;){
      await frame();beforeAcknowledgement.push({mode:button.dataset.mode,opacity:getComputedStyle(button).opacity});
    }
    SpicyQA.send('commandResult',{requestId:request.requestId,accepted:true});
    SpicyQA.observe(off);await wait(160);SpicyQA.observe(off);await frame();
    const confirmedOpacity=Number(getComputedStyle(button).opacity);
    check('native Off arriving before dispatch acknowledgement never paints a temporary dim flash',
      beforeAcknowledgement.length>=3 && beforeAcknowledgement.every(s=>s.mode==='smart' && Number(s.opacity)>=.85)
        && button.dataset.mode==='off' && confirmedOpacity>=.85 && !button.classList.contains('pending'),
      {beforeAcknowledgement,confirmedOpacity});
    check('a pending shuffle command cannot dispatch a duplicate',
      SpicyQA.messages.filter(m=>m.type==='toggleShuffle').length===count);
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
      Syllables:[{Text:'Stay',StartTime:0,EndTime:.8},{Text:'close',StartTime:.8,EndTime:1.6}]},
      Background:[{StartTime:0,EndTime:2,Syllables:[{Text:'Echo',StartTime:0,EndTime:.8}]}]}];
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
    const backing=getComputedStyle(document.querySelector('.background.active .token'));
    const backingLift=new DOMMatrix(backing.transform).m42/em;
    if(surface!=='inline') check(`${surface}: backing vocals lift in the desktop lead-size coordinate system`,
      Math.abs(backingLift+0.03534979423868313)<.002,{backingLift,leadLift:y});
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
      backing:gradient('linear-gradient(90deg,rgba(255,255,255,.85) 40%,rgba(255,255,255,.3) 60%)')
    };
    check(`${surface}: highlighted backing matches lead brightness while its unsung sweep stays dim`,
      actual.lead===expected.lead && actual.backing===expected.backing,{actual,expected});
    const underpaint = [...document.querySelectorAll('.lyric-line.active > .line-text')]
      .map(e=>({gradient:getComputedStyle(e).backgroundImage,clip:getComputedStyle(e).backgroundClip}));
    const underpaintExpected=gradient('linear-gradient(180deg,rgba(255,255,255,.85) -20%,rgba(255,255,255,.35) 0%)');
    check(`${surface}: active syllables retain the desktop glyph-clipped row underpaint`,
      underpaint.length>0 && underpaint.every(s=>s.gradient===underpaintExpected&&s.clip==='text'),underpaint);
    SpicyQA.observe({...paused,positionMs:0});await frame();await frame();
    const initialStyle=getComputedStyle(lead);
    const initial={gradient:initialStyle.backgroundImage,fill:initialStyle.webkitTextFillColor,
      position:parseFloat(initialStyle.getPropertyValue('--gradient-position'))};
    check(`${surface}: desktop sweep starts before the glyph edge`,
      initial.position===-20 && (initial.gradient===gradient('linear-gradient(90deg,rgba(255,255,255,.85) -20%,rgba(255,255,255,.5) 0%)')
        || (initial.gradient==='none' && initial.fill==='rgba(255, 255, 255, 0.5)')),initial);
    SpicyQA.observe({...paused,positionMs:800});await frame();await frame();
    const finishedStyle=getComputedStyle(lead);
    const finished={gradient:finishedStyle.backgroundImage,fill:finishedStyle.webkitTextFillColor,
      position:parseFloat(finishedStyle.getPropertyValue('--gradient-position'))};
    check(`${surface}: completed words retain desktop white without a clipped overlay`,
      finished.position===100 && (finished.gradient===gradient('linear-gradient(90deg,rgba(255,255,255,.85) 100%,rgba(255,255,255,.5) 120%)')
        || (finished.gradient==='none' && finished.fill==='rgba(255, 255, 255, 0.85)'))
        && ['none','normal'].includes(getComputedStyle(lead,'::after').content),finished);
    SpicyQA.lyrics.line.Content=[{Type:'Vocal',Text:'Stay with me',StartTime:0,EndTime:4}];
    SpicyQA.scenario('line',{...paused,positionMs:2000});await frame();await frame();
    const wholeLine = getComputedStyle(document.querySelector('.line-timed.active > .line-text')).backgroundImage;
    check(`${surface}: line-only lyrics use the desktop whole-line gradient, not invented word timing`,
      wholeLine===gradient('linear-gradient(180deg,rgba(255,255,255,.85) 50%,rgba(255,255,255,.35) 70%)')
        && !document.querySelector('.line-timed .token'),wholeLine);
    const lineTransition = getComputedStyle(document.querySelector('.line-timed.active > .line-text')).transitionProperty;
    check(`${surface}: the desktop spring owns glyph glow without an additional CSS shadow transition`,
      !lineTransition.split(',').map(value=>value.trim()).some(value=>value==='text-shadow'||value==='all'),lineTransition);
    reference.remove();
  }
  if (phase.startsWith('desktop-dot-envelope-')) {
    const surface = phase.slice('desktop-dot-envelope-'.length);
    bootstrap(surface);
    SpicyQA.lyrics.line.Content = [
      {Type:'Vocal',Text:'Stay with me',StartTime:0,EndTime:2},
      {Type:'Vocal',Text:'Here we go',StartTime:8,EndTime:11}
    ];
    SpicyQA.scenario('line',{...paused,positionMs:1000});
    await document.fonts.ready;await wait(450);await waitForSteadyFrames();
    const row=document.querySelector('.interlude'), group=row.querySelector('.dot-group');
    const sample = () => ({time:performance.now(),opacity:Number(getComputedStyle(row).opacity),
      scale:parseFloat(getComputedStyle(group).scale),height:row.getBoundingClientRect().height});
    const enteredAt=performance.now();
    SpicyQA.observe({...paused,positionMs:2100});
    const entrance=[];
    for(const deadline=performance.now()+420;performance.now()<deadline;){await frame();entrance.push(sample());}
    check(`${surface}: pause-row entrance fades through intermediate frames instead of appearing fully opaque`,
      entrance.filter(s=>s.opacity>.05 && s.opacity<.95).length>=3
        && entrance.at(-1).opacity===1 && entrance.at(-1).scale>=.99,entrance);
    check(`${surface}: mobile entrance remains visibly fading beyond the short PC row fade`,
      entrance.some(s=>s.time-enteredAt>=150 && s.time-enteredAt<=220 && s.opacity>.1 && s.opacity<.98),
      entrance.map(s=>({elapsed:s.time-enteredAt,opacity:s.opacity})));
    SpicyQA.observe({...paused,positionMs:1000});await wait(450);await waitForSteadyFrames();
    SpicyQA.observe({...paused,positionMs:2100});
    const uninterrupted=[];let bootstrappedAt=null;
    const start=performance.now();
    for(const deadline=start+420;performance.now()<deadline;){
      await frame();uninterrupted.push(sample());
      if(bootstrappedAt===null && performance.now()-start>=60){bootstrappedAt=performance.now();bootstrap(surface);}
    }
    // PC entry is 300 ms ease: cubic-bezier(.25,.1,.25,1), whose maximum
    // dy/dx is below 2.3. A 70 ms sampling gap can legitimately grow by .386;
    // a fixed .32 delta incorrectly called that a snap before bootstrap ran.
    // Bound growth by elapsed time, allow .03 for style/sample clock rounding,
    // and still require three painted intermediate frames AFTER the input.
    // Cancelling the old entrance at ~60 ms jumps to 1 and fails both guards.
    const jumps=uninterrupted.slice(1).map((s,i)=>({dt:s.time-uninterrupted[i].time,
      delta:Math.abs(s.scale-uninterrupted[i].scale)}))
      .filter(s=>s.delta>s.dt*(2.3/300)+.03);
    const intermediateAfterBootstrap=uninterrupted.filter(s=>s.time>bootstrappedAt && s.scale>.05 && s.scale<.99).length;
    check(`${surface}: a native bootstrap during entrance does not snap the dots to full size`,
      bootstrappedAt!==null && uninterrupted.length>=8 && intermediateAfterBootstrap>=3
        && !jumps.length && uninterrupted.at(-1).scale>=.99,
      {samples:uninterrupted,jumps,bootstrappedAt,intermediateAfterBootstrap});
    SpicyQA.observe({...paused,positionMs:7520});
    const exit=[];
    for(const deadline=performance.now()+470;performance.now()<deadline;){
      await frame();exit.push({...sample(),groupOpacity:Number(getComputedStyle(group).opacity)});
    }
    check(`${surface}: pause-dot exit fades before its row collapses`,
      exit.filter(s=>s.groupOpacity>.05 && s.groupOpacity<.95).length>=5
        && exit.every(s=>s.height>0) && exit.at(-1).groupOpacity===0 && exit.at(-1).scale===0,exit);
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
    const exitStarted = performance.now(), exitStartedAtMs = Date.now();
    SpicyQA.observe({...paused,positionMs:7520});
    const exiting = [], exitFrames = [];
    for (const end = performance.now()+470; performance.now()<end;) {
      await frame();
      const style = getComputedStyle(group()), scale = parseFloat(style.scale);
      exiting.push(scale);
      exitFrames.push({elapsed:performance.now()-exitStarted,scale,opacity:Number(style.opacity)});
    }
    const exitedScale = getComputedStyle(group()).scale;
    SpicyQA.observe({...paused,positionMs:8100}); await wait(300);
    const after = row.getBoundingClientRect().height;
    check(`${surface}: pause dots enter, finish, exit and release their row`,
      before === 0 && activeHeight > 0
        && entering.some(s=>s.scale>.05&&s.scale<.95)
        && entering.at(-1).scale>=.99
        && exiting.some(s=>s>.05&&s<.95) && Number(exitedScale)===0 && after===0,
      {before,activeHeight,entering,exiting,exitFrames,exitStartedAtMs,exitedScale,after});
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
  // Page construction measures and wraps every provider word. On a cold
  // WebKit process its first composite can outlast a fixed 350 ms timer.
  // Establish the same actually painted starting phrase as the simple-caption
  // check, then observe a steady cadence before sending the page-change input.
  // The transition window and intermediate-opacity assertion remain unchanged.
  await waitForPaintedCaption(Array.from({length:20},(_,i)=>`Pageword${i} `).join(''));
  const pageCadenceBeforeMs = await waitForSteadyFrames();
  const nativeFrame = window.requestAnimationFrame;
  const pageCallbacks = [], pageFrameTimes = [], pageStyleReads = [], pageLayerProfiles = [];
  let recordPageFrames = true;
  window.requestAnimationFrame = callback => nativeFrame.call(window, timestamp => {
    const started = performance.now();
    callback(timestamp);
    if (recordPageFrames) pageCallbacks.push({name:callback.name,ms:performance.now()-started});
  });
  const pageStarted = performance.now(), pageStartedAtMs = Date.now();
  SpicyQA.observe({ ...paused, positionMs: 15500 });
  const pageOpacity = [];
  const pageGhosts = [];
  let hiddenPageWrites = 0, hiddenPageNodes = 0, hiddenPageObserver = null;
  for (const deadline = performance.now() + 350; performance.now() < deadline;) {
    await frame();
    pageFrameTimes.push(performance.now()-pageStarted);
    const pageReadStarted = performance.now();
    pageOpacity.push(Number(getComputedStyle(document.querySelector('#lyrics .inline-visible')).opacity));
    pageStyleReads.push(performance.now()-pageReadStarted);
    const ghost = document.querySelector('.caption-outgoing');
    if (ghost) pageGhosts.push({ hidden: ghost.querySelectorAll('[hidden]').length,
      tokens: ghost.querySelectorAll('.token').length });
    if (!hiddenPageObserver) {
      const hidden = [...document.querySelectorAll('#lyrics .inline-visible .word-group[hidden]')];
      hiddenPageNodes = hidden.length;
      hiddenPageObserver = new MutationObserver(records => { hiddenPageWrites += records.length; });
      hidden.forEach(node => hiddenPageObserver.observe(node,
        { attributes: true, attributeFilter: ['style'], subtree: true }));
    }
  }
  recordPageFrames = false;
  window.requestAnimationFrame = nativeFrame;
  hiddenPageObserver?.disconnect();
  const currentWord = [...document.querySelectorAll('#lyrics .inline-visible .token')].find(e=>e.textContent==='Pageword15 ');
  check('caption word-boundary pages blend and keep the actual timed word visible',
    pageOpacity.some(o=>o>.05&&o<.95) && currentWord.getClientRects().length>0 && !document.querySelector('.caption-outgoing'),
    {opacity:pageOpacity,frameTimes:pageFrameTimes,startedAtMs:pageStartedAtMs,cadenceBeforeMs:pageCadenceBeforeMs,
      styleReads:pageStyleReads,callbacks:pageCallbacks,layerProfiles:pageLayerProfiles});
  check('the outgoing caption snapshot contains only its visible word-boundary page',
    pageGhosts.length > 0 && pageGhosts.every(g=>g.hidden===0 && g.tokens>0 && g.tokens<20),pageGhosts);
  check('hidden caption pages do not receive repeated glyph style writes during a page transition',
    hiddenPageNodes > 0 && hiddenPageWrites === 0,{hiddenPageNodes,hiddenPageWrites});
  if (desktopPaint) {
    const uniformLetters = [...document.querySelectorAll('#lyrics .inline-visible .letter')]
      .filter(letter => letter.getClientRects().length)
      .filter(letter => [-20,100].includes(parseFloat(letter.style.getPropertyValue('--gradient-position'))))
      .map(letter => ({position:parseFloat(letter.style.getPropertyValue('--gradient-position')),
        background:getComputedStyle(letter).backgroundImage,fill:getComputedStyle(letter).webkitTextFillColor}));
    check('caption uniform glyphs retain desktop ink alpha without repeated gradient masks',
      uniformLetters.length > 1 && uniformLetters.every(letter => letter.background === 'none'
        && letter.fill === (letter.position === -20 ? 'rgba(255, 255, 255, 0.5)' : 'rgba(255, 255, 255, 0.85)')),
      uniformLetters);
  }
  SpicyQA.observe({ ...paused, positionMs: 500 });
  await frame();
  const rewoundWord = [...document.querySelectorAll('#lyrics .inline-visible .token')].find(e=>e.textContent==='Pageword0 ');
  check('rewinding to an earlier caption page restores its real provider word progress',
    rewoundWord.getClientRects().length>0 && Math.abs(parseFloat(rewoundWord.style.getPropertyValue('--fill'))-50)<.01
      && Math.abs(parseFloat(rewoundWord.style.getPropertyValue('--gradient-position'))-40)<.01,
    {fill:rewoundWord.style.getPropertyValue('--fill'),gradient:rewoundWord.style.getPropertyValue('--gradient-position')});
  // Test-only A/B/A diagnosis of WebKit's frame delivery. These overrides do
  // not change the original assertion above and are removed before any other
  // phase. No diagnostic style is included in the shipped renderer.
  if (desktopPaint) {
    const profileStyle = document.createElement('style');
    document.head.appendChild(profileStyle);
    try {
      for (const [variant, css] of [
        ['control-before', ''],
        ['gpu-translate', '.token,.letter { transform:translate3d(0,calc(var(--effect-y,.01) * var(--lead-font-size)),0)!important; }'],
        ['glyph-motion-off', '.token,.letter { transform:none!important;scale:1!important; }'],
        ['glyph-gradient-off', '.token,.letter { background-image:none!important;-webkit-text-fill-color:white!important; }'],
        ['flat-glyph-paint', '.lyric-line.active > .line-text,.token,.letter { background-image:none!important;-webkit-text-fill-color:white!important;text-shadow:none!important; }.lyric-line.effects-near,.lyric-line.effects-near * {will-change:auto!important;backface-visibility:visible!important}.token,.letter{transform:none!important;scale:1!important}'],
        ['adjacent-page', ''],
        ['control-after', '']
      ]) {
        profileStyle.textContent = css;
        SpicyQA.scenario('karaoke', { ...paused, positionMs: variant === 'adjacent-page' ? 2500 : 500 });
        await wait(350);
        const before = [];
        for (let i = 0; i < 6; i++) { await frame(); before.push(performance.now()); }
        const started = performance.now(), times = [], opacities = [];
        SpicyQA.observe({ ...paused, positionMs: variant === 'adjacent-page' ? 3500 : 15500 });
        for (const end = started + 400; performance.now() < end;) {
          await frame();
          times.push(performance.now() - started);
          opacities.push(Number(getComputedStyle(document.querySelector('#lyrics .inline-visible')).opacity));
        }
        pageLayerProfiles.push({variant,before:before.slice(1).map((t,i)=>t-before[i]),times,opacities});
      }
    } finally { profileStyle.remove(); }
  }
  }

  if (phase === 'card') {
  bootstrap('card');
  SpicyQA.lyrics.line.Content = Array.from({ length: 30 }, (_, i) => ({
    Type: 'Vocal', Text: `Preview phrase ${i}`, StartTime: i * 2, EndTime: i * 2 + 2
  }));
  SpicyQA.scenario('line', { ...paused, positionMs: 2100, durationMs: 60000 });
  await wait(700);
  const previewCadence = await waitForSteadyFrames();
  const scroller = document.querySelector('#lyrics-scroller');
  const start = scroller.scrollTop;
  const previewStarted = performance.now(), previewStartedAtMs = Date.now();
  SpicyQA.observe({ ...paused, positionMs: 4100, durationMs: 60000 });
  const positions = [], colors = [], previewFrameTimes = [];
  for (const deadline = performance.now() + 450; performance.now() < deadline;) {
    await frame();
    positions.push(scroller.scrollTop);
    previewFrameTimes.push(performance.now()-previewStarted);
    colors.push(desktopPaint ? getComputedStyle(document.querySelector('.line-timed.active')).opacity
      : getComputedStyle(document.querySelector('.line-timed.active .line-text')).webkitTextFillColor);
  }
  const end = positions.at(-1);
  const intermediate = positions.filter(p => p > start + 1 && p < end - 1);
  check('preview scroll has multiple intermediate positions, not a teleport',
    end > start + 10 && new Set(intermediate).size >= 4
      && positions.every((p, i) => !i || p >= positions[i - 1] - 1),
    {start,positions,frameTimes:previewFrameTimes,cadenceBeforeMs:previewCadence,startedAtMs:previewStartedAtMs});
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
  const seekHolds = [], seekHoldDetails = [];
  for (const [positionMs, index] of [[21900,10], [31900,15]]) {
    const observedAt = performance.now();
    SpicyQA.observe({ ...paused, positionMs, durationMs: 60000 });
    await wait(280);
    const leads = [...document.querySelectorAll('.lyric-line.lead')];
    const bright = leads.filter(line => [...line.querySelectorAll('.token')].every(token =>
      token.style.getPropertyValue('--fill') === '100.00%' && brightToken(token)));
    seekHolds.push(bright.length === 1 && bright[0] === leads[index] && !document.querySelector('#lyrics [aria-current]'));
    seekHoldDetails.push({positionMs,index,elapsedMs:performance.now()-observedAt,
      bright:bright.map(line=>leads.indexOf(line)),
      active:leads.filter(line=>line.hasAttribute('aria-current')).map(line=>leads.indexOf(line)),
      held:leads.filter(line=>line.classList.contains('preview-held')).map(line=>leads.indexOf(line)),
      nearby:leads.map((line,i)=>({line,index:i})).filter(({index:i})=>Math.abs(i-index)<=3)
        .map(({line,index:i})=>({index:i,opacity:Number(getComputedStyle(line).opacity),
        tokens:[...line.querySelectorAll('.token')].map(token=>({fill:token.style.getPropertyValue('--fill'),
          bright:brightToken(token),background:getComputedStyle(token).backgroundImage,
          ink:getComputedStyle(token).webkitTextFillColor,gradient:token.style.getPropertyValue('--gradient-position')}))}))});
  }
  check('backward and forward gap observations hold only the correct preview line', seekHolds.every(Boolean),
    {passed:seekHolds,observations:seekHoldDetails});

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
    check('fullscreen cover retains only a light blur for clear artwork detail',
      coverBlur > 0 && coverBlur <= 2, {blurPx:coverBlur});
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
