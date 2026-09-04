#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$page = Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html'
$url = ([Uri](Resolve-Path $page).Path).AbsoluteUri
$artifacts = Join-Path $repo 'artifacts\spicy-v5.3-qa\continuity'
$session = "spicy-v53-continuity-$PID"
New-Item -ItemType Directory -Force -Path $artifacts | Out-Null
function Eval-Qa([string]$script) {
    $raw = $script | & agent-browser --session $session eval --stdin
    if ($LASTEXITCODE -ne 0) { throw "Browser evaluation failed: $raw" }
    return ($raw | ConvertFrom-Json) | ConvertFrom-Json
}
function Require-Qa([string]$name, $value) {
    if (-not $value.pass) { throw "$name failed: $($value | ConvertTo-Json -Compress -Depth 9)" }
    Write-Host "PASS $name $($value | ConvertTo-Json -Compress -Depth 9)"
}
try {
    & agent-browser --session $session open $url
    & agent-browser --session $session set viewport 393 852
    Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Write-Host
    Require-Qa 'drag follows immediately, cancellation sends no seek' (Eval-Qa @'
(async () => {
  SpicyQA.lyrics.line.Content = Array.from({length:30}, (_,i) => ({Type:'Vocal',Text:`Test line ${i}`,StartTime:i,EndTime:i+1}));
  SpicyQA.scenario('line', {positionMs:0,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  SpicyQA.clearMessages();
  const seek=document.querySelector('#seek'), scroller=document.querySelector('#lyrics-scroller');
  const errors=[];
  for (const value of [500,6500,13500,27000]) {
    seek.value=String(value); seek.dispatchEvent(new Event('input',{bubbles:true}));
    await new Promise(requestAnimationFrame);
    const active=document.querySelector('.lyric-line.active');
    const wanted=Math.max(0,Math.min(scroller.scrollHeight-scroller.clientHeight,
      active.offsetTop-scroller.clientHeight*.42+active.offsetHeight*.5));
    errors.push(Math.abs(scroller.scrollTop-wanted));
  }
  seek.dispatchEvent(new PointerEvent('pointercancel',{bubbles:true}));
  seek.dispatchEvent(new Event('change',{bubbles:true}));
  await new Promise(requestAnimationFrame);
  return JSON.stringify({pass:Math.max(...errors)<2 && !SpicyQA.messages.some(m=>m.type==='seek')
    && Number(seek.value)===0, errors,position:Number(seek.value),commands:SpicyQA.messages.map(m=>m.type)});
})()
'@)
    Require-Qa 'measured delivery age and stale transport rejection' (Eval-Qa @'
(async () => {
  const base=SpicyQA.observe({positionMs:1000,isPlaying:true,isPaused:false,isAdvancing:true});
  SpicyQA.send('session',{...base,sequence:String(Number(base.sequence)+10),sampledAtEpochMs:Date.now()-350});
  await new Promise(requestAnimationFrame);
  const compensated=Number(document.querySelector('#seek').value);
  SpicyQA.clearMessages();
  SpicyQA.send('session',{...base,sequence:String(Number(base.sequence)+11),positionMs:20000,sampledAtEpochMs:Date.now()-5000});
  await new Promise(requestAnimationFrame);
  const afterOld=Number(document.querySelector('#seek').value);
  return JSON.stringify({pass:compensated>=1300&&compensated<1600&&afterOld<1700
    &&SpicyQA.messages.filter(m=>m.type==='resync').length===1,compensated,afterOld});
})()
'@)
    & agent-browser --session $session set viewport 360 320
    Require-Qa 'card replaces lyric content, highlights and opens full screen' (Eval-Qa @'
(async () => {
  SpicyQA.send('bootstrap',{surface:'card',preferences:{fontSize:100},reduceMotion:false});
  SpicyQA.scenario('karaoke',{positionMs:7500,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(r=>setTimeout(r,350));
  const active=document.querySelector('.lyric-line.active.lead'), token=active.querySelector('.token');
  const before=getComputedStyle(document.body).backgroundColor;
  const hidden=['.player-bar','.topbar','.media-pane'].every(s=>getComputedStyle(document.querySelector(s)).display==='none');
  SpicyQA.clearMessages(); active.click();
  const opened=SpicyQA.messages.filter(m=>m.type==='openFullscreen').length===1;
  const fill=parseFloat(token.style.getPropertyValue('--fill'));
  const overflow=[...document.querySelectorAll('.lyric-line')].some(e=>e.getBoundingClientRect().right>innerWidth+1);
  document.documentElement.style.backgroundColor='#80618f'; // native host's background, not shipped CSS
  return JSON.stringify({pass:before==='rgba(0, 0, 0, 0)'&&hidden&&opened&&fill>0&&!overflow,before,hidden,opened,fill,overflow});
})()
'@)
    & agent-browser --session $session screenshot (Join-Path $artifacts 'card-karaoke.png')
    Require-Qa 'card line-timed and untimed fallback' (Eval-Qa @'
(async () => {
  SpicyQA.scenario('line',{positionMs:4500,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  const lineWhite=getComputedStyle(document.querySelector('.lyric-line.active')).color==='rgb(255, 255, 255)';
  SpicyQA.scenario('static',{positionMs:4500,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  return JSON.stringify({pass:lineWhite&&!document.querySelector('.lyric-line.active')
    &&document.querySelectorAll('.lyric-line.static').length===4,lineWhite});
})()
'@)
    & agent-browser --session $session set viewport 340 52
    Require-Qa 'above-title word timing without duplicate lyrics or controls' (Eval-Qa @'
(async () => {
  SpicyQA.send('bootstrap',{surface:'inline',preferences:{fontSize:100}});
  SpicyQA.scenario('karaoke',{positionMs:7500,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  const visible=[...document.querySelectorAll('.lyric-line')].filter(e=>e.getClientRects().length);
  const box=visible[0].getBoundingClientRect();
  SpicyQA.clearMessages(); visible[0].click();
  return JSON.stringify({pass:visible.length===1&&box.left>=-1&&box.right<=innerWidth+1&&box.height<=innerHeight+1
    &&SpicyQA.messages.some(m=>m.type==='openFullscreen'),count:visible.length,text:visible[0].textContent,box:{left:box.left,right:box.right,height:box.height}});
})()
'@)
    & agent-browser --session $session screenshot (Join-Path $artifacts 'above-title-karaoke.png')
    Require-Qa 'above-title untimed text stays readable without fabricated highlight' (Eval-Qa @'
(async () => {
  SpicyQA.scenario('static',{positionMs:4500,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  const shown=[...document.querySelectorAll('.lyric-line')].filter(e=>e.getClientRects().length);
  return JSON.stringify({pass:shown.length===1&&shown[0].textContent.includes('Static lyrics')
    &&!document.querySelector('.lyric-line.active'),count:shown.length,text:shown[0]?.textContent});
})()
'@)
    $errors = & agent-browser --session $session errors
    if (($errors | Out-String).Trim()) { throw "Browser console errors: $errors" }
} finally {
    & agent-browser --session $session close | Out-Null
}
Write-Host 'Spicy Lyrics continuity and compact-surface QA passed'
