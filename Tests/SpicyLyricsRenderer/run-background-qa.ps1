#requires -Version 7.0
param([switch]$ReportOnly)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$page = Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html'
$session = "spicy-background-$PID"
try {
    & agent-browser --session $session open ([Uri]$page).AbsoluteUri
    & agent-browser --session $session set viewport 393 852 | Out-Null
    Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Out-Null
    $script = @'
(async () => {
  const canvas = document.createElement('canvas'); canvas.width = canvas.height = 64;
  const context = canvas.getContext('2d');
  context.fillStyle = '#365b87'; context.fillRect(0,0,64,64);
  context.fillStyle = '#b96b40'; context.fillRect(32,0,32,64);
  const artwork = canvas.toDataURL();
  SpicyQA.sendSession({ isPlaying:false, isPaused:true, isAdvancing:false,
    track:{id:'qa-karaoke',title:'Artwork sample',artist:'Two-tone cover',artwork} });
  await new Promise(resolve => setTimeout(resolve,650));
  const backdrop = document.querySelector('#artwork-backdrop'), style = getComputedStyle(backdrop);
  const bounds = backdrop.getBoundingClientRect();
  const result = {name:'fullscreen displays the blurred song cover edge-to-edge',
    opacity:Number(style.opacity),filter:style.filter,
    pass:style.backgroundImage.includes(artwork) && Number(style.opacity) >= .9
      && parseFloat(style.filter.match(/blur\(([^)]+)/)?.[1] || '0') >= 30
      && bounds.left <= 0 && bounds.top <= 0 && bounds.right >= innerWidth && bounds.bottom >= innerHeight};
  return JSON.stringify(result);
})()
'@
    $raw = $script | & agent-browser --session $session eval --stdin
    if ($LASTEXITCODE -ne 0) { throw "Browser evaluation failed: $raw" }
    $result = ($raw | ConvertFrom-Json) | ConvertFrom-Json
    Write-Host ($result | ConvertTo-Json -Compress -Depth 5)
    if (!$ReportOnly -and !$result.pass) { throw 'Blurred-cover presentation failed' }
    & agent-browser --session $session set viewport 852 393 | Out-Null
    $landscape = @'
(() => {
  const pane = document.querySelector('.lyrics-pane').getBoundingClientRect();
  const hidden = ['.media-pane','#mini-cover'].every(selector => getComputedStyle(document.querySelector(selector)).display === 'none');
  return JSON.stringify({name:'landscape uses the full lyric stage without a cover tile',
    hidden,lyricWidth:pane.width,pass:hidden && pane.width >= innerWidth * .8
      && getComputedStyle(document.querySelector('.mini-track')).display !== 'none'});
})()
'@ | & agent-browser --session $session eval --stdin
    $result = ($landscape | ConvertFrom-Json) | ConvertFrom-Json
    Write-Host ($result | ConvertTo-Json -Compress -Depth 5)
    if (!$ReportOnly -and !$result.pass) { throw 'Landscape artwork removal failed' }
    $fallback = @'
(async () => {
  SpicyQA.scenario('next', {isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(requestAnimationFrame);
  const cover = document.querySelector('#cover');
  return JSON.stringify({name:'a song without artwork has no previous image or stale artwork description',
    alt:cover.alt,pass:!cover.hasAttribute('src') && cover.alt === ''
      && getComputedStyle(document.querySelector('#artwork-backdrop')).backgroundImage === 'none'});
})()
'@ | & agent-browser --session $session eval --stdin
    $result = ($fallback | ConvertFrom-Json) | ConvertFrom-Json
    Write-Host ($result | ConvertTo-Json -Compress -Depth 5)
    if (!$ReportOnly -and !$result.pass) { throw 'Missing-artwork fallback failed' }
} finally { & agent-browser --session $session close | Out-Null }
