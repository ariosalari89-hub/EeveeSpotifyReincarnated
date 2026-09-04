$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$rendererPath = Join-Path $repoRoot "layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html"
$rendererUrl = ([Uri](Resolve-Path $rendererPath).Path).AbsoluteUri
$fixturePath = Join-Path $PSScriptRoot "browser-fixture.js"
$artifactDirectory = Join-Path $repoRoot "artifacts\spicy-v5-qa\automated"
$session = "spicy-v5-automated"

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

try {
    & agent-browser --session $session open $rendererUrl | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Could not open renderer" }
    & agent-browser --session $session set viewport 393 852 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Could not set portrait viewport" }
    Get-Content -LiteralPath $fixturePath -Raw |
        & agent-browser --session $session eval --stdin | Out-Host
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

    $lyricsModes = Invoke-QaEval @'
(async () => {
  window.SpicyQA.scenario("line", {generation:2,positionMs:5500,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  const lineTiming = document.querySelector("#lyrics").dataset.timing;
  const activeLine = document.querySelector(".lyric-line.active");
  const activeText = activeLine?.textContent.trim() || "";
  const activeColor = activeLine ? getComputedStyle(activeLine).color : "";
  window.SpicyQA.scenario("static", {generation:3,positionMs:25000,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  const staticTiming = document.querySelector("#lyrics").dataset.timing;
  const staticCount = document.querySelectorAll(".lyric-line.static").length;
  const fabricatedActive = document.querySelectorAll(".lyric-line.active").length;
  return JSON.stringify({
    pass: lineTiming === "line" && activeText === "This line is active"
      && activeColor === "rgb(255, 255, 255)" && staticTiming === "static"
      && staticCount === 4 && fabricatedActive === 0,
    lineTiming, activeText, activeColor, staticTiming, staticCount, fabricatedActive
  });
})()
'@
    Require-Qa "line/static semantics" $lyricsModes

    $transport = Invoke-QaEval @'
(async () => {
  window.SpicyQA.scenario("karaoke", {generation:4,positionMs:7500,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  window.SpicyQA.clearMessages();
  document.querySelector("#shuffle-button").click();
  const shuffle = window.SpicyQA.messages.find((message) => message.type === "toggleShuffle");
  window.SpicyQA.send("commandResult", {requestId:shuffle.requestId,command:"toggleShuffle",generation:"4",accepted:true});
  window.SpicyQA.observe({positionMs:7500,isPlaying:false,isPaused:true,isAdvancing:false,shuffleEnabled:true});
  document.querySelector("#repeat-button").click();
  const repeat = window.SpicyQA.messages.find((message) => message.type === "cycleRepeat");
  window.SpicyQA.send("commandResult", {requestId:repeat.requestId,command:"cycleRepeat",generation:"4",accepted:true});
  window.SpicyQA.observe({positionMs:7500,isPlaying:false,isPaused:true,isAdvancing:false,shuffleEnabled:true,repeatMode:"context"});
  document.querySelector("#next-button").click();
  const next = window.SpicyQA.messages.find((message) => message.type === "next");
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
    pass: shuffle.generation === "4" && repeat.generation === "4" && next.generation === "4"
      && title === "Next Song" && timing === "line" && pending === 0
      && titleAfterStale === "Next Song",
    shuffleGeneration:shuffle.generation, repeatGeneration:repeat.generation,
    nextGeneration:next.generation, title, timing, pending, titleAfterStale
  });
})()
'@
    Require-Qa "observed controls and atomic skip" $transport

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

    & agent-browser --session $session screenshot (Join-Path $artifactDirectory "portrait-karaoke.png") | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Could not capture portrait baseline" }

    & agent-browser --session $session set viewport 852 393 | Out-Host
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
    & agent-browser --session $session screenshot (Join-Path $artifactDirectory "landscape-settings.png") | Out-Host
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
