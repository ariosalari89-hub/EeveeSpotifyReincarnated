#requires -Version 7.0
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$rendererPath = Join-Path $repoRoot "layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html"
$rendererUrl = ([Uri](Resolve-Path $rendererPath).Path).AbsoluteUri
$fixturePath = Join-Path $PSScriptRoot "browser-fixture.js"
$artifactDirectory = Join-Path $repoRoot "artifacts\spicy-v5.4-qa\automated"
$session = "spicy-v5.4-automated-$PID"

New-Item -ItemType Directory -Force -Path $artifactDirectory | Out-Null

function Invoke-QaEval {
    param([Parameter(Mandatory)][string]$Script)

    $raw = $Script | & agent-browser --session $session eval --stdin
    if ($LASTEXITCODE -ne 0) { throw "Browser evaluation failed: $raw" }
    $inner = $raw | ConvertFrom-Json
    return $inner | ConvertFrom-Json
}

function Require-Qa {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Result
    )

    if (-not $Result.pass) {
        throw "$Name failed: $($Result | ConvertTo-Json -Compress -Depth 12)"
    }
    Write-Host "PASS $Name $($Result | ConvertTo-Json -Compress -Depth 12)"
}

function Test-QaAccessibility {
    param([Parameter(Mandatory)][string]$State)
    $raw = & agent-browser --session $session a11y --json
    if ($LASTEXITCODE -ne 0) { throw "Accessibility audit failed: $raw" }
    $audit = $raw | ConvertFrom-Json
    if (-not $audit.success -or $audit.data.violations.Count -gt 0) {
        throw "$State accessibility violations: $raw"
    }
    if (@($audit.data.incomplete | Where-Object { $_.id -eq 'aria-prohibited-attr' }).Count -gt 0) {
        throw "$State has unsupported ARIA: $raw"
    }
    Write-Host "PASS $State automated accessibility (gradient contrast requires separate review)"
}

try {
    # Do not capture the first command's stdout: on Windows the freshly spawned
    # browser daemon inherits that pipe and keeps it open after `open` exits.
    & agent-browser --session $session open $rendererUrl
    if ($LASTEXITCODE -ne 0) { throw "Could not open renderer" }
    $viewportOutput = & agent-browser --session $session set viewport 393 852
    $viewportOutput | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "Could not set portrait viewport" }
    $fixture = Get-Content -LiteralPath $fixturePath -Raw -Encoding utf8
    $fixtureOutput = $fixture | & agent-browser --session $session eval --stdin
    $fixtureOutput | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "Could not install browser fixture" }

    $pauseResume = Invoke-QaEval @'
(async () => {
  window.SpicyQA.observe({positionMs:5000,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  const pauseStart = Number(document.querySelector("#seek").value);
  await new Promise((resolve) => setTimeout(resolve, 350));
  const pauseEnd = Number(document.querySelector("#seek").value);
  window.SpicyQA.observe({positionMs:5000,isPlaying:true,isPaused:false,isAdvancing:true});
  await new Promise((resolve) => setTimeout(resolve, 350));
  const resumed = Number(document.querySelector("#seek").value);
  window.SpicyQA.observe({positionMs:resumed,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise((resolve) => setTimeout(resolve, 350));
  const secondPause = Number(document.querySelector("#seek").value);
  return JSON.stringify({
    pass: pauseStart === 5000 && pauseEnd === 5000 && resumed > 5150
      && resumed < 6200 && secondPause === resumed,
    pauseStart, pauseEnd, resumed, secondPause
  });
})()
'@
    Require-Qa "pause/resume clock" $pauseResume

    $buttonDispatch = Invoke-QaEval @'
(async () => {
  const play = document.querySelector("#play-button");
  window.SpicyQA.observe({positionMs:5000,isPlaying:true,isPaused:false,isAdvancing:true});
  window.SpicyQA.clearMessages();
  play.click();
  play.click();
  const requests = window.SpicyQA.messages.filter(m => ["play","pause","togglePlay"].includes(m.type));
  const pause = requests[0];
  window.SpicyQA.send("commandResult", {requestId:pause?.requestId,accepted:true});
  window.SpicyQA.observe({positionMs:5200,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  const paused = play.getAttribute("aria-label") === "Play" && !play.classList.contains("pending");
  play.click();
  const resume = window.SpicyQA.messages.filter(m => m.type === "play")[0];
  window.SpicyQA.send("commandResult", {requestId:resume?.requestId,accepted:true});
  window.SpicyQA.observe({positionMs:5200,isPlaying:true,isPaused:false,isAdvancing:true});
  await new Promise(requestAnimationFrame);
  return JSON.stringify({pass:requests.length === 1 && pause?.type === "pause" && paused
    && resume?.type === "play" && play.getAttribute("aria-label") === "Pause" && !play.classList.contains("pending"),
    requestTypes:requests.map(m => m.type),paused,resumeType:resume?.type});
})()
'@
    Require-Qa "explicit pause/play button dispatch and duplicate tap protection" $buttonDispatch

    $seek = Invoke-QaEval @'
(async () => {
  window.SpicyQA.observe({positionMs:7000,isPlaying:false,isPaused:true,isAdvancing:false});
  window.SpicyQA.clearMessages();
  const control = document.querySelector("#seek");
  for (const value of [9000, 12500, 17000, 20000]) {
    control.value = String(value);
    control.dispatchEvent(new Event("input", {bubbles:true}));
  }
  control.dispatchEvent(new Event("change", {bubbles:true}));
  const commands = window.SpicyQA.messages.filter((message) => message.type === "seek");
  const request = commands[0];
  window.SpicyQA.send("commandResult", {
    requestId: request?.requestId,
    command: "seek",
    generation: "1",
    accepted: true
  });
  window.SpicyQA.observe({positionMs:7600,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  const held = Number(control.value);
  const pendingBefore = control.classList.contains("pending");
  window.SpicyQA.observe({positionMs:19900,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  const confirmed = Number(control.value);
  const pendingAfter = control.classList.contains("pending");
  return JSON.stringify({
    pass: commands.length === 1 && commands[0].positionMs === 20000
      && held === 20000 && pendingBefore && confirmed === 19900 && !pendingAfter,
    commandCount: commands.length, held, pendingBefore, confirmed, pendingAfter
  });
})()
'@
    Require-Qa "single-command seek reconciliation" $seek

    $rapidSeek = Invoke-QaEval @'
(async () => {
  window.SpicyQA.observe({positionMs:7000,isPlaying:false,isPaused:true,isAdvancing:false});
  window.SpicyQA.clearMessages();
  const control = document.querySelector("#seek");
  control.value = "12000";
  control.dispatchEvent(new Event("input", {bubbles:true}));
  control.dispatchEvent(new Event("change", {bubbles:true}));
  const first = window.SpicyQA.messages.find((message) => message.type === "seek");
  control.value = "25000";
  control.dispatchEvent(new Event("input", {bubbles:true}));
  control.dispatchEvent(new Event("change", {bubbles:true}));
  const commands = window.SpicyQA.messages.filter((message) => message.type === "seek");
  const second = commands[1];
  window.SpicyQA.send("commandResult", {
    requestId:first?.requestId,command:"seek",generation:"1",accepted:false
  });
  window.SpicyQA.observe({positionMs:7600,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  const heldAfterOldResult = Number(control.value);
  window.SpicyQA.send("commandResult", {
    requestId:second?.requestId,command:"seek",generation:"1",accepted:true
  });
  // The playback slider has a 100 ms HTML step. Use a representable observed
  // value so this assertion tests stale-preview release instead of the browser's
  // standards-defined half-step rounding.
  window.SpicyQA.observe({positionMs:24900,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise((resolve) => setTimeout(resolve, 50));
  const confirmed = Number(control.value);
  const pending = document.querySelectorAll(".pending").length;
  return JSON.stringify({
    pass: commands.length === 2 && first.requestId !== second.requestId
      && heldAfterOldResult === 25000 && confirmed === 24900 && pending === 0,
    commandCount:commands.length,heldAfterOldResult,confirmed,pending
  });
})()
'@
    Require-Qa "superseded seek isolation" $rapidSeek

    $lyricsModes = Invoke-QaEval @'
(async () => {
  window.SpicyQA.scenario("line", {generation:2,positionMs:5500,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  const lineTiming = document.querySelector("#lyrics").dataset.timing;
  const activeLine = document.querySelector(".lyric-line.active");
  const activeText = activeLine?.textContent.trim() || "";
  const activeColor = activeLine ? getComputedStyle(activeLine).color : "";
  const activePaint = activeLine ? getComputedStyle(activeLine.querySelector('.line-text')) : null;
  const lineHighlighted = window.SpicyLyricsEffects
    ? activePaint?.backgroundImage.includes('linear-gradient(')
      && activePaint.getPropertyValue('--gradient-degrees').trim()==='180deg'
      && activePaint.webkitTextFillColor==='rgba(0, 0, 0, 0)' && !activeLine.querySelector('.token')
    : activeColor === "rgb(255, 255, 255)";
  window.SpicyQA.scenario("static", {generation:3,positionMs:25000,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  const staticTiming = document.querySelector("#lyrics").dataset.timing;
  const staticCount = document.querySelectorAll(".lyric-line.static").length;
  const fabricatedActive = document.querySelectorAll(".lyric-line.active").length;
  return JSON.stringify({
    pass: lineTiming === "line" && activeText === "This line is active"
      && lineHighlighted && staticTiming === "static"
      && staticCount === 4 && fabricatedActive === 0,
    lineTiming, activeText, lineHighlighted, activeColor, staticTiming, staticCount, fabricatedActive
  });
})()
'@
    Require-Qa "line/static semantics" $lyricsModes

    $transport = Invoke-QaEval @'
(async () => {
  window.SpicyQA.scenario("karaoke", {generation:4,positionMs:7500,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  window.SpicyQA.clearMessages();
  const latest = (type) => [...window.SpicyQA.messages].reverse().find((message) => message.type === type);
  document.querySelector("#shuffle-button").click();
  const shuffle = latest("toggleShuffle");
  window.SpicyQA.send("commandResult", {requestId:shuffle.requestId,command:"toggleShuffle",generation:"4",accepted:true});
  window.SpicyQA.observe({positionMs:7500,isPlaying:false,isPaused:true,isAdvancing:false,shuffleEnabled:true});

  document.querySelector("#repeat-button").click();
  const repeatContext = latest("cycleRepeat");
  window.SpicyQA.send("commandResult", {requestId:repeatContext.requestId,command:"cycleRepeat",generation:"4",accepted:true});
  window.SpicyQA.observe({positionMs:7500,isPlaying:false,isPaused:true,isAdvancing:false,shuffleEnabled:true,repeatMode:"context"});
  const contextMode = document.querySelector("#repeat-button").dataset.mode;
  document.querySelector("#repeat-button").click();
  const repeatTrack = latest("cycleRepeat");
  window.SpicyQA.send("commandResult", {requestId:repeatTrack.requestId,command:"cycleRepeat",generation:"4",accepted:true});
  window.SpicyQA.observe({positionMs:7500,isPlaying:false,isPaused:true,isAdvancing:false,shuffleEnabled:true,repeatMode:"track"});
  const trackMode = document.querySelector("#repeat-button").dataset.mode;
  document.querySelector("#repeat-button").click();
  const repeatOff = latest("cycleRepeat");
  window.SpicyQA.send("commandResult", {requestId:repeatOff.requestId,command:"cycleRepeat",generation:"4",accepted:true});
  window.SpicyQA.observe({positionMs:7500,isPlaying:false,isPaused:true,isAdvancing:false,shuffleEnabled:true,repeatMode:"off"});
  const offMode = document.querySelector("#repeat-button").dataset.mode;
  const offPressed = document.querySelector("#repeat-button").getAttribute("aria-pressed");

  window.SpicyQA.observe({positionMs:7500,isPlaying:false,isPaused:true,isAdvancing:false,shuffleEnabled:true,repeatMode:"context",canToggleRepeatTrack:false,canToggleRepeatContext:true});
  const restrictedLabel = document.querySelector("#repeat-button").getAttribute("aria-label");
  const restrictedDisabled = document.querySelector("#repeat-button").disabled;
  document.querySelector("#repeat-button").click();
  const repeatFallback = latest("cycleRepeat");
  window.SpicyQA.send("commandResult", {requestId:repeatFallback.requestId,command:"cycleRepeat",generation:"4",accepted:true});
  window.SpicyQA.observe({positionMs:7500,isPlaying:false,isPaused:true,isAdvancing:false,shuffleEnabled:true,repeatMode:"off",canToggleRepeatTrack:false,canToggleRepeatContext:true});

  document.querySelector("#previous-button").click();
  const previous = latest("previous");
  window.SpicyQA.send("commandResult", {requestId:previous.requestId,command:"previous",generation:"4",accepted:true});
  window.SpicyQA.observe({positionMs:100,isPlaying:true,isPaused:false,isAdvancing:true,shuffleEnabled:true,repeatMode:"off"});
  const previousPending = document.querySelector("#previous-button").classList.contains("pending");

  document.querySelector("#next-button").click();
  const next = latest("next");
  window.SpicyQA.send("commandResult", {requestId:next.requestId,command:"next",generation:"4",accepted:true});
  window.SpicyQA.scenario("next", {generation:5,positionMs:100});
  await new Promise(requestAnimationFrame);
  const title = document.querySelector("#title").textContent;
  const timing = document.querySelector("#lyrics").dataset.timing;
  const pending = document.querySelectorAll(".pending").length;
  window.SpicyQA.send("session", {
    generation:"4", sequence:"9999", trackId:"qa-karaoke", positionMs:25000,
    durationMs:30000, playbackRate:1, isPlaying:true, isPaused:false,
    isAdvancing:true, requiresFreshObservation:false, track:window.SpicyQA.tracks.karaoke
  });
  await new Promise(requestAnimationFrame);
  const titleAfterStale = document.querySelector("#title").textContent;
  return JSON.stringify({
    pass: shuffle.generation === "4" && repeatContext.generation === "4"
      && repeatTrack.generation === "4" && repeatOff.generation === "4"
      && repeatFallback.generation === "4" && previous.generation === "4"
      && next.generation === "4" && contextMode === "context" && trackMode === "track"
      && offMode === "off" && offPressed === "false"
      && restrictedLabel === "Turn repeat off" && !restrictedDisabled && !previousPending
      && title === "Next Song" && timing === "line" && pending === 0
      && titleAfterStale === "Next Song",
    contextMode,trackMode,offMode,offPressed,restrictedLabel,restrictedDisabled,
    previousPending,nextGeneration:next.generation,title,timing,pending,titleAfterStale
  });
})()
'@
    Require-Qa "observed controls, repeat cycle, and atomic skips" $transport

    $smartShuffle = Invoke-QaEval @'
(async () => {
  window.SpicyQA.observe({shuffleEnabled:true,shuffleMode:"shuffle",smartShuffleAvailable:true});
  const button = document.querySelector("#shuffle-button");
  button.click();
  const request = [...window.SpicyQA.messages].reverse().find(m => m.type === "toggleShuffle");
  window.SpicyQA.send("commandResult", {requestId:request.requestId,accepted:true});
  window.SpicyQA.observe({shuffleEnabled:true,shuffleMode:"smart",smartShuffleAvailable:true});
  await new Promise(resolve => setTimeout(resolve,160));
  window.SpicyQA.observe({shuffleEnabled:true,shuffleMode:"smart",smartShuffleAvailable:true});
  await new Promise(requestAnimationFrame);
  const smart = button.dataset.mode === "smart" && !button.classList.contains("pending")
    && getComputedStyle(button.querySelector(".smart-shuffle-mark")).display !== "none"
    && button.getAttribute("aria-label").includes("Smart Shuffle");
  button.click();
  const offRequest = [...window.SpicyQA.messages].reverse().find(m => m.type === "toggleShuffle");
  window.SpicyQA.send("commandResult", {requestId:offRequest.requestId,accepted:true});
  window.SpicyQA.observe({shuffleEnabled:false,shuffleMode:"off",smartShuffleAvailable:true});
  await new Promise(resolve => setTimeout(resolve,160));
  window.SpicyQA.observe({shuffleEnabled:false,shuffleMode:"off",smartShuffleAvailable:true});
  await new Promise(requestAnimationFrame);
  const off = button.dataset.mode === "off" && button.getAttribute("aria-pressed") === "false"
    && getComputedStyle(button.querySelector(".smart-shuffle-mark")).display === "none";
  return JSON.stringify({pass:smart && off,smart,off});
})()
'@
    Require-Qa "smart shuffle observed state and glyph" $smartShuffle

    $lifecycle = Invoke-QaEval @'
(async () => {
  window.SpicyQA.scenario("karaoke", {generation:6,positionMs:7500,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  window.SpicyQA.send("lifecycle", {state:"hidden"});
  window.SpicyQA.observe({positionMs:10000,isPlaying:true,isPaused:false,isAdvancing:false,requiresFreshObservation:true});
  window.SpicyQA.send("lifecycle", {state:"visible"});
  await new Promise(requestAnimationFrame);
  const gated = Number(document.querySelector("#seek").value);
  window.SpicyQA.observe({positionMs:10000,isPlaying:true,isPaused:false,isAdvancing:true,requiresFreshObservation:false});
  await new Promise(requestAnimationFrame);
  const released = Number(document.querySelector("#seek").value);
  return JSON.stringify({pass:gated === 7500 && released >= 10000,gated,released});
})()
'@
    Require-Qa "background/foreground freshness gate" $lifecycle

    $longLyrics = Invoke-QaEval @'
(async () => {
  window.SpicyQA.observe({positionMs:6500,isPlaying:false,isPaused:true,isAdvancing:false});
  window.SpicyQA.send("lyrics", {state:"ready",trackId:"qa-karaoke",generation:"6",data:{
    Type:"Syllable",Content:[
      {Type:"Vocal",OppositeAligned:true,Lead:{StartTime:0,EndTime:14,Syllables:Array.from({length:14},(_,i)=>({
        Text:"Day-",StartTime:i,EndTime:i+1,IsPartOfWord:true
      }))}},
      {Type:"Vocal",Lead:{StartTime:15,EndTime:30,Syllables:[
        {Text:"Aye, ",StartTime:15,EndTime:18},
        {Text:"Panini",StartTime:18,EndTime:21},
        {Text:"don't you be a meanie",StartTime:21,EndTime:30}
      ]},Background:[{StartTime:18,EndTime:21,Syllables:[{Text:'Additional vocal',StartTime:18,EndTime:21}]}]}
    ]
  }});
  window.SpicyQA.send("bootstrap", {preferences:{fontSize:126}});
  await new Promise(r => setTimeout(r, 600));
  const all = [...document.querySelectorAll(".lyric-line,.word-group,.token,.transport button,.timeline,#settings-button")];
  const overflow = all.filter(e => {const r=e.getBoundingClientRect(); return r.left < -1 || r.right > innerWidth+1;}).map(e=>e.className||e.id);
  return JSON.stringify({pass:overflow.length===0 && document.querySelectorAll(".word-group.breakable").length>0,
    overflow,breakable:document.querySelectorAll(".word-group.breakable").length});
})()
'@
    Require-Qa "Panini long joined lyrics at enlarged text" $longLyrics
    $contrastStyles = Invoke-QaEval @'
(async () => {
  const canvas = document.createElement('canvas'); canvas.width = canvas.height = 8;
  const context = canvas.getContext('2d'); context.fillStyle = 'white';context.fillRect(0,0,8,8);
  const artwork = canvas.toDataURL();
  SpicyQA.send('bootstrap',{highContrast:true,preferences:{fontSize:82}});
  SpicyQA.sendSession({positionMs:6500,isPlaying:false,isPaused:true,isAdvancing:false,
    track:{...SpicyQA.tracks.karaoke,artwork}});
  for (let i=0;i<120&&!getComputedStyle(document.querySelector('#artwork-backdrop')).backgroundImage.includes(artwork);i++) {
    await new Promise(requestAnimationFrame);
  }
  if (!getComputedStyle(document.querySelector('#artwork-backdrop')).backgroundImage.includes(artwork)) throw new Error('White cover did not load');
  // The contrast preference changes line opacity through its normal 200ms
  // transition; sample the settled glyph paint, not that intermediate frame.
  await new Promise(r=>setTimeout(r,300));
  const color = selector => {
    const element=document.querySelector(selector), style=getComputedStyle(element), line=element.closest('.lyric-line');
    return line && window.SpicyLyricsEffects
      ? [255,255,255,parseFloat(style.getPropertyValue('--gradient-alpha-end'))*Number(getComputedStyle(line).opacity)]
      : style.color.match(/[\d.]+/g).map(Number);
  };
  const opaqueLines = [...document.querySelectorAll('.lyric-line')].every(e=>getComputedStyle(e).opacity==='1');
  document.querySelector('#app').style.visibility = 'hidden';
  return JSON.stringify({colors:{inactive:color('.token'),artist:color('#artist'),timeline:color('.timeline'),
    backgroundVocal:color('.background .token')},opaqueLines,
    backgroundFontPx:parseFloat(getComputedStyle(document.querySelector('.background')).fontSize)});
})()
'@
    $whiteBackground = Join-Path $artifactDirectory 'worst-case-white-background.png'
    & agent-browser --session $session screenshot $whiteBackground | Out-Null
    $contrastRaw = & python (Join-Path $PSScriptRoot 'check-contrast.py') $whiteBackground ($contrastStyles | ConvertTo-Json -Compress -Depth 5)
    if ($LASTEXITCODE -ne 0) { throw 'Pixel contrast measurement failed' }
    $contrast = $contrastRaw | ConvertFrom-Json
    Write-Host "MEASURE Increase Contrast $contrastRaw styles=$($contrastStyles | ConvertTo-Json -Compress -Depth 5)"
    if ($contrast.ratios.backgroundVocal -lt 5) { throw 'Small background vocals fail conservative normal-text contrast' }
    Write-Host "PASS minimum-size background vocal contrast $($contrast.ratios.backgroundVocal) at $($contrastStyles.backgroundFontPx)px"
    $null = Invoke-QaEval "(()=>{document.querySelector('#app').style.visibility='';SpicyQA.send('bootstrap',{preferences:{fontSize:126}});return JSON.stringify({restored:true});})()"
    Require-Qa "Increase Contrast lyric and metadata contrast against worst-case white artwork" $contrast
    Test-QaAccessibility "portrait karaoke"

    & agent-browser --session $session set viewport 280 240 | Out-Null
    $previewStyles = Invoke-QaEval @'
(async () => {
  SpicyQA.send('bootstrap',{surface:'card',highContrast:true,preferences:{fontSize:82,dynamicBackground:false}});
  const canvas = document.createElement('canvas'); canvas.width = canvas.height = 8;
  const context = canvas.getContext('2d'); context.fillStyle = 'white'; context.fillRect(0,0,8,8);
  const artwork = canvas.toDataURL();
  SpicyQA.sendSession({positionMs:6500,isPlaying:false,isPaused:true,isAdvancing:false,
    track:{...SpicyQA.tracks.karaoke,artwork}});
  await new Promise(r=>setTimeout(r,350));
  if (!getComputedStyle(document.querySelector('#artwork-backdrop')).backgroundImage.includes(artwork)) throw new Error('Preview white cover did not load');
  const color = selector => {
    const element=document.querySelector(selector), style=getComputedStyle(element), line=element.closest('.lyric-line');
    return line && window.SpicyLyricsEffects
      ? [255,255,255,parseFloat(style.getPropertyValue('--gradient-alpha-end'))*Number(getComputedStyle(line).opacity)]
      : style.color.match(/[\d.]+/g).map(Number);
  };
  const opaqueLines = [...document.querySelectorAll('.lyric-line')].every(e=>getComputedStyle(e).opacity==='1');
  document.querySelector('#app').style.visibility = 'hidden';
  return JSON.stringify({colors:{inactive:color('.lead.not-sung .token'),artist:color('#artist'),
    timeline:color('.timeline'),backgroundVocal:color('.background .token')},opaqueLines,
    fontPx:parseFloat(getComputedStyle(document.querySelector('.lead.not-sung')).fontSize),
    backgroundFontPx:parseFloat(getComputedStyle(document.querySelector('.background')).fontSize)});
})()
'@
    $previewBackground = Join-Path $artifactDirectory 'preview-worst-case-white-background.png'
    & agent-browser --session $session screenshot $previewBackground | Out-Null
    $previewContrastRaw = & python (Join-Path $PSScriptRoot 'check-contrast.py') $previewBackground ($previewStyles | ConvertTo-Json -Compress -Depth 5)
    if ($LASTEXITCODE -ne 0) { throw 'Preview pixel contrast measurement failed' }
    $previewContrast = $previewContrastRaw | ConvertFrom-Json
    Write-Host "MEASURE preview Increase Contrast $previewContrastRaw styles=$($previewStyles | ConvertTo-Json -Compress -Depth 5)"
    if ($previewContrast.ratios.inactive -lt 5 -or $previewContrast.ratios.backgroundVocal -lt 5) {
        throw "Minimum-size preview lyrics fail normal-text contrast: $previewContrastRaw"
    }
    Require-Qa "Increase Contrast minimum-size preview contrast against worst-case white artwork" $previewContrast
    Write-Host "PASS preview text sizes measured at $($previewStyles.fontPx)px and $($previewStyles.backgroundFontPx)px"
    $null = Invoke-QaEval "(()=>{document.querySelector('#app').style.visibility='';SpicyQA.send('bootstrap',{surface:'fullscreen',preferences:{fontSize:126}});return JSON.stringify({restored:true});})()"
    & agent-browser --session $session set viewport 393 852 | Out-Null

    $portraitOutput = & agent-browser --session $session screenshot (Join-Path $artifactDirectory "portrait-karaoke.png")
    $portraitOutput | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "Could not capture portrait baseline" }

    $landscapeOutput = & agent-browser --session $session set viewport 852 393
    $landscapeOutput | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "Could not set landscape viewport" }
    $layout = Invoke-QaEval @'
(async () => {
  window.SpicyQA.observe({positionMs:7500,isPlaying:false,isPaused:true,isAdvancing:false});
  window.SpicyQA.send("bootstrap", {reduceMotion:false,preferences:{romanized:false,translations:true,dynamicBackground:true,fontSize:126,playbackOffset:0}});
  await new Promise(requestAnimationFrame);
  const ids = ["close-button","settings-button","shuffle-button","previous-button","play-button","next-button","repeat-button"];
  const rectangles = ids.map((id) => ({id, rect:document.getElementById(id).getBoundingClientRect()}));
  const overflow = rectangles.filter(({rect}) => rect.left < 0 || rect.top < 0 || rect.right > innerWidth || rect.bottom > innerHeight).map(({id}) => id);
  const undersized = rectangles.filter(({rect}) => rect.width < 44 || rect.height < 44).map(({id}) => id);
  const stage = document.querySelector(".stage").getBoundingClientRect();
  const bar = document.querySelector(".player-bar").getBoundingClientRect();
  document.querySelector("#settings-button").click();
  await new Promise(requestAnimationFrame);
  const sheet = document.querySelector("#settings-sheet");
  const sheetRect = sheet.getBoundingClientRect();
  const dialogValid = sheet.getAttribute("role") === "dialog"
    && sheet.getAttribute("aria-modal") === "true" && document.querySelector("#app").inert;
  return JSON.stringify({
    pass: overflow.length === 0 && undersized.length === 0 && stage.bottom <= bar.top
      && sheetRect.left >= 0 && sheetRect.top >= 0 && sheetRect.right <= innerWidth
      && sheetRect.bottom <= innerHeight && dialogValid,
    overflow, undersized, stageBottom:stage.bottom, barTop:bar.top,
    sheet:{left:sheetRect.left,top:sheetRect.top,right:sheetRect.right,bottom:sheetRect.bottom},
    dialogValid
  });
})()
'@
    Require-Qa "landscape, enlarged text, and modal geometry" $layout
    Test-QaAccessibility "landscape settings"
    $landscapeScreenshotOutput = & agent-browser --session $session screenshot (Join-Path $artifactDirectory "landscape-settings.png")
    $landscapeScreenshotOutput | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "Could not capture landscape baseline" }

    $browserErrors = & agent-browser --session $session errors
    if ($LASTEXITCODE -ne 0) { throw "Could not read browser errors" }
    if (($browserErrors | Out-String).Trim()) {
        throw "Browser console errors were reported: $browserErrors"
    }
    Write-Host "PASS browser console has no errors"
} finally {
    & agent-browser --session $session close | Out-Null
}

Write-Host "Spicy Lyrics browser QA passed"
