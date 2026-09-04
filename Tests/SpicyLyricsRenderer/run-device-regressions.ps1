#requires -Version 7.0
param([string]$RendererPage = '')
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$page = Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html'
if ($RendererPage) { $page = $RendererPage }
$url = ([Uri](Resolve-Path $page).Path).AbsoluteUri
$session = "spicy-v54-gestures-$PID"
$artifacts = Join-Path $repo 'artifacts\spicy-v5.4-qa\gestures'
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
    $thumb = Eval-Qa @'
(async () => {
  SpicyQA.scenario('line',{positionMs:10000,durationMs:30000,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame); SpicyQA.clearMessages();
  const seek=document.querySelector('#seek'),r=seek.getBoundingClientRect();
  return JSON.stringify({x:r.left+7+(r.width-14)/3,y:r.top+r.height/2,left:r.left,right:r.right});
})()
'@
    Write-Host "Measured seek thumb: $($thumb | ConvertTo-Json -Compress)"
    & agent-browser --session $session mouse move ([int]$thumb.x) ([int]$thumb.y)
    & agent-browser --session $session mouse down
    Require-Qa 'holding the untouched thumb owns position before the first input' (Eval-Qa @'
(async () => {
  SpicyQA.observe({positionMs:20000,isPlaying:true,isPaused:false,isAdvancing:true});
  await new Promise(r=>setTimeout(r,220));
  const value=Number(document.querySelector('#seek').value);
  return JSON.stringify({pass:Math.abs(value-10000)<150&&!SpicyQA.messages.some(m=>m.type==='seek'),value});
})()
'@)
    & agent-browser --session $session mouse move ([int]($thumb.right - 35)) ([int]$thumb.y)
    & agent-browser --session $session mouse move ([int]($thumb.left + 75)) ([int]$thumb.y)
    Require-Qa 'real drag previews the finger and sends no intermediate native seeks' (Eval-Qa @'
(() => { const value=Number(document.querySelector('#seek').value);
  return JSON.stringify({pass:value>7000&&value<10500&&!SpicyQA.messages.some(m=>m.type==='seek'),value}); })()
'@)
    & agent-browser --session $session screenshot (Join-Path $artifacts 'seek-drag.png')
    & agent-browser --session $session mouse up
    Require-Qa 'actual pointer release commits one seek' (Eval-Qa @'
(() => { const seeks=SpicyQA.messages.filter(m=>m.type==='seek');
  return JSON.stringify({pass:seeks.length===1&&seeks[0].positionMs>7000&&seeks[0].positionMs<10500,seeks}); })()
'@)
    & agent-browser --session $session set viewport 360 320
    $null = Eval-Qa @'
(async () => {
  SpicyQA.send('bootstrap',{surface:'card',preferences:{fontSize:100},reduceMotion:false});
  SpicyQA.lyrics.line.Content=Array.from({length:30},(_,i)=>({Type:'Vocal',Text:`Preview line ${i}`,StartTime:i*2,EndTime:i*2+2}));
  SpicyQA.scenario('line',{positionMs:1000,durationMs:60000,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(r=>setTimeout(r,350)); return JSON.stringify({ready:true});
})()
'@
    & agent-browser --session $session mouse move 180 200
    & agent-browser --session $session scroll down 360
    Require-Qa 'preview auto-follow survives actual wheel and visibility reentry' (Eval-Qa @'
(async () => {
  SpicyQA.send('lifecycle',{state:'hidden'});
  SpicyQA.send('lifecycle',{state:'resuming'});
  SpicyQA.observe({positionMs:45000,durationMs:60000,isPlaying:false,isPaused:true,isAdvancing:false});
  SpicyQA.send('lifecycle',{state:'visible'});
  await new Promise(r=>setTimeout(r,850));
  const active=document.querySelector('.active'),r=active.getBoundingClientRect();
  return JSON.stringify({pass:active.textContent==='Preview line 22'&&r.top>=0&&r.bottom<=innerHeight,
    text:active.textContent,top:r.top,bottom:r.bottom,height:innerHeight});
})()
'@)
    & agent-browser --session $session screenshot (Join-Path $artifacts 'preview-follow.png')
    Require-Qa 'untimed preview remains readable and opens without inventing timing' (Eval-Qa @'
(async () => {
  SpicyQA.scenario('static',{positionMs:4000,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame); SpicyQA.clearMessages();
  document.querySelector('.lyric-line.static').click();
  return JSON.stringify({pass:SpicyQA.messages.filter(m=>m.type==='openFullscreen').length===1
    &&!SpicyQA.messages.some(m=>m.type==='seek')&&!document.querySelector('.active')});
})()
'@)
    & agent-browser --session $session set viewport 340 52
    Require-Qa 'word-boundary caption pages follow timed words and dots are inset' (Eval-Qa @'
(async () => {
  SpicyQA.send('bootstrap',{surface:'inline',preferences:{fontSize:100}});
  SpicyQA.lyrics.karaoke.Content=[{Type:'Vocal',Lead:{StartTime:0,EndTime:30,Syllables:
    Array.from({length:15},(_,i)=>({Text:`Timedword${i} `,StartTime:i*2,EndTime:i*2+2}))}}];
  SpicyQA.scenario('karaoke',{positionMs:25000,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  const text=document.querySelector('.inline-visible .line-text'),word=[...text.querySelectorAll('.token')].find(e=>e.textContent.includes('Timedword12'));
  const range=document.createRange(); range.selectNodeContents(text);
  const rects=[...range.getClientRects()].filter(r=>r.height>0&&r.width>0);
  const fits=rects.every(r=>r.left>=0&&r.right<=innerWidth&&r.top>=0&&r.bottom<=innerHeight);
  return JSON.stringify({pass:word.getClientRects().length>0&&fits&&getComputedStyle(text).textOverflow!=='ellipsis',fits,
    visible:[...text.querySelectorAll('.word-group')].filter(e=>!e.hidden).map(e=>e.textContent)});
})()
'@)
    & agent-browser --session $session screenshot (Join-Path $artifacts 'caption-pages.png')
    Require-Qa 'line-timed full phrase fits without ellipsis' (Eval-Qa @'
(async () => {
  SpicyQA.lyrics.line.Content=[{Type:'Vocal',Text:'A longer phrase belongs here and must remain readable without being cut',StartTime:0,EndTime:10}];
  SpicyQA.scenario('line',{positionMs:5000,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  const text=document.querySelector('.inline-visible .line-text');
  const range=document.createRange(); range.selectNodeContents(text);
  const rects=[...range.getClientRects()];
  return JSON.stringify({pass:rects.every(r=>r.left>=0&&r.right<=innerWidth&&r.top>=0&&r.bottom<=innerHeight)
    &&getComputedStyle(text).textOverflow!=='ellipsis',rects:rects.map(r=>({left:r.left,right:r.right,top:r.top,bottom:r.bottom}))});
})()
'@)
    & agent-browser --session $session screenshot (Join-Path $artifacts 'caption-line.png')
    Require-Qa 'interlude dots fit the left edge at maximum fill' (Eval-Qa @'
(async () => {
  SpicyQA.lyrics.karaoke.Content=[{Type:'Interlude',StartTime:0,EndTime:9},{Type:'Vocal',Lead:{StartTime:10,EndTime:12,Syllables:[{Text:'End',StartTime:10,EndTime:12}]}}];
  SpicyQA.scenario('karaoke',{positionMs:7500,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  const rects=[...document.querySelectorAll('.inline-visible .dot')].map(e=>e.getBoundingClientRect());
  return JSON.stringify({pass:rects.length===3&&rects.every(r=>r.left>=4&&r.right<=innerWidth-4&&r.top>=0&&r.bottom<=innerHeight),
    rects:rects.map(r=>({left:r.left,right:r.right,top:r.top,bottom:r.bottom}))});
})()
'@)
    & agent-browser --session $session screenshot (Join-Path $artifacts 'caption-dots.png')
    & agent-browser --session $session set viewport 852 393
    Require-Qa 'landscape keeps one copy of metadata in bottom left' (Eval-Qa @'
(async () => {
  SpicyQA.send('bootstrap',{surface:'fullscreen'}); SpicyQA.scenario('karaoke');
  await new Promise(requestAnimationFrame);
  return JSON.stringify({pass:!document.querySelector('#title').getClientRects().length
    &&document.querySelector('#mini-title').getClientRects().length>0
    &&document.querySelector('#mini-title').textContent==='Any Time'});
})()
'@)
    & agent-browser --session $session screenshot (Join-Path $artifacts 'landscape-metadata.png')
    $errors = & agent-browser --session $session errors
    if (($errors | Out-String).Trim()) { throw "Browser errors: $errors" }
} finally { & agent-browser --session $session close | Out-Null }
Write-Host 'Device-reported browser regressions passed'
