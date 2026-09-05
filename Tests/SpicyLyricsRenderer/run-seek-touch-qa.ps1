#requires -Version 7.0
param([switch]$ReportOnly, [int]$Width = 393, [int]$Height = 852)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$page = Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html'
$session = "spicy-seek-touch-$PID"
$failures = [Collections.Generic.List[string]]::new()
function Eval-Qa([string]$script) {
    $raw = $script | & agent-browser --session $session eval --stdin
    if ($LASTEXITCODE -ne 0) { throw "Browser evaluation failed: $raw" }
    return ($raw | ConvertFrom-Json) | ConvertFrom-Json
}
function Check-Qa([string]$name, $result) {
    $prefix = if ($result.pass) { 'PASS' } else { $failures.Add($name); 'FAIL' }
    Write-Host "$prefix $name $($result | ConvertTo-Json -Compress -Depth 8)"
}
function Touch-Qa([string]$type, [double]$x = 0, [double]$y = 0) {
    & node (Join-Path $PSScriptRoot 'send-touch.js') $port $type $x $y
    if ($LASTEXITCODE -ne 0) { throw 'Touch input failed' }
}
function Reset-Qa {
    Eval-Qa @'
(async () => {
  SpicyQA.send('lifecycle',{state:'visible'});
  SpicyQA.scenario('line',{positionMs:10000,durationMs:30000,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame);
  SpicyQA.clearMessages();
  const s=document.querySelector('#seek'),r=s.getBoundingClientRect();
  return JSON.stringify({x:r.left+7+(r.width-14)/3,y:r.top+r.height/2,left:r.left,right:r.right,width:r.width});
})()
'@
}
try {
    & agent-browser --session $session open ([Uri]$page).AbsoluteUri
    & agent-browser --session $session set viewport $Width $Height
    Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Write-Host
    $stream = & agent-browser --session $session stream status --json | ConvertFrom-Json
    $port = $stream.data.port
    $null = Eval-Qa @'
(() => {
  window.touchReceipt=[];
  ['pointerdown','pointermove','pointerup','pointercancel'].forEach(type=>document.addEventListener(type,e=>touchReceipt.push({type:e.type,trusted:e.isTrusted,kind:e.pointerType,target:e.target.id,button:e.button,x:e.clientX,y:e.clientY}),true));
  return JSON.stringify({ready:true});
})()
'@
    $r = Reset-Qa
    Write-Host "Seek bounds $($r | ConvertTo-Json -Compress)"
    Check-Qa 'touch has no browser tint or callout; semantic slider keeps 44px target' (Eval-Qa @'
(() => { const e=document.querySelector('#seek'),s=getComputedStyle(e),r=e.getBoundingClientRect();
  return JSON.stringify({pass:s.webkitTapHighlightColor==='rgba(0, 0, 0, 0)' && s.userSelect==='none' && r.height>=44 && e.type==='range',
    highlight:s.webkitTapHighlightColor,selection:s.userSelect,callout:s.getPropertyValue('-webkit-touch-callout'),height:r.height}); })()
'@)
    # Start inside the accessible target but above the tiny painted thumb.
    Touch-Qa touchStart ($r.x+5) ($r.y-16)
    Check-Qa 'touch hold does not draw a rectangular focus box' (Eval-Qa @'
(() => { const s=getComputedStyle(document.querySelector('#seek'));
  return JSON.stringify({pass:s.outlineStyle==='none'||parseFloat(s.outlineWidth)===0,outline:s.outline}); })()
'@)
    Check-Qa 'holding the thumb touch target does not jump or leak playback updates' (Eval-Qa @'
(async () => { SpicyQA.observe({positionMs:17000,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(r=>setTimeout(r,650)); const value=Number(document.querySelector('#seek').value);
  return JSON.stringify({pass:Math.abs(value-10000)<100 && !SpicyQA.messages.some(m=>m.type==='seek'),value}); })()
'@)
    Touch-Qa touchMove ($r.x+55) ($r.y-62)
    Check-Qa 'drift outside the rail continues smoothly from the grab point' (Eval-Qa @'
(() => { const e=document.querySelector('#seek'),width=e.getBoundingClientRect().width;
  const expected=10000+50/(width-14)*30000,value=Number(e.value);
  return JSON.stringify({pass:Math.abs(value-expected)<160 && !SpicyQA.messages.some(m=>m.type==='seek'),value,expected}); })()
'@)
    Touch-Qa touchEnd
    Check-Qa 'touch release commits exactly once after drifting outside' (Eval-Qa @'
(() => { const seeks=SpicyQA.messages.filter(m=>m.type==='seek');
  return JSON.stringify({pass:seeks.length===1,seeks,trusted:touchReceipt.every(e=>e.trusted&&e.kind==='touch'),events:touchReceipt}); })()
'@)
    $r = Reset-Qa
    Touch-Qa touchStart $r.x $r.y
    Touch-Qa touchMove ($r.right-15) $r.y
    Touch-Qa touchCancel
    Check-Qa 'touch cancellation restores observed position without a seek' (Eval-Qa @'
(async () => { await new Promise(requestAnimationFrame); const value=Number(document.querySelector('#seek').value);
  return JSON.stringify({pass:Math.abs(value-10000)<100&&!SpicyQA.messages.some(m=>m.type==='seek'),value}); })()
'@)
    $r = Reset-Qa
    Touch-Qa touchStart $r.x $r.y
    Touch-Qa touchMove ($r.right-20) $r.y
    $null = Eval-Qa "(() => { SpicyQA.send('lifecycle',{state:'hidden'}); SpicyQA.send('lifecycle',{state:'resuming'}); SpicyQA.observe({positionMs:4000,isPlaying:false,isPaused:true,isAdvancing:false}); SpicyQA.send('lifecycle',{state:'visible'}); return JSON.stringify({done:true}); })()"
    Touch-Qa touchEnd
    Check-Qa 'background interruption cannot commit an old held gesture on return' (Eval-Qa @'
(async () => { await new Promise(requestAnimationFrame); const value=Number(document.querySelector('#seek').value);
  return JSON.stringify({pass:Math.abs(value-4000)<100&&!SpicyQA.messages.some(m=>m.type==='seek'),value,messages:SpicyQA.messages}); })()
'@)
    $r = Reset-Qa
    Touch-Qa touchStart $r.x $r.y
    $null = Eval-Qa "(() => { SpicyQA.scenario('next',{positionMs:2000,isPlaying:false,isPaused:true,isAdvancing:false}); return JSON.stringify({done:true}); })()"
    Touch-Qa touchMove ($r.right-20) $r.y
    Touch-Qa touchEnd
    Check-Qa 'song change cancels the old touch without seeking the new song' (Eval-Qa @'
(() => { const value=Number(document.querySelector('#seek').value);
  return JSON.stringify({pass:Math.abs(value-2000)<100&&!SpicyQA.messages.some(m=>m.type==='seek'),value,messages:SpicyQA.messages}); })()
'@)
    $r = Reset-Qa
    Touch-Qa touchStart ($r.left-25) $r.y
    Touch-Qa touchMove ($r.right-20) $r.y
    Touch-Qa touchEnd
    Check-Qa 'touch beginning on elapsed text cannot become a seek' (Eval-Qa @'
(() => { const value=Number(document.querySelector('#seek').value);
  return JSON.stringify({pass:value===10000&&!SpicyQA.messages.some(m=>m.type==='seek'),value}); })()
'@)
    $r = Reset-Qa
    & agent-browser --session $session focus '#seek'
    & agent-browser --session $session press ArrowRight
    Check-Qa 'keyboard still changes the semantic slider and commits' (Eval-Qa @'
(() => { const e=document.querySelector('#seek'),seeks=SpicyQA.messages.filter(m=>m.type==='seek');
  return JSON.stringify({pass:seeks.length===1&&seeks[0].positionMs>10000&&document.activeElement===e
    &&parseFloat(getComputedStyle(e).outlineWidth)>=2,seeks,outline:getComputedStyle(e).outline}); })()
'@)
    $errors = & agent-browser --session $session errors
    if (($errors | Out-String).Trim()) { throw "Browser errors: $errors" }
} finally { & agent-browser --session $session close | Out-Null }
if ($failures.Count -and !$ReportOnly) { throw "Seek regressions: $($failures -join ', ')" }
