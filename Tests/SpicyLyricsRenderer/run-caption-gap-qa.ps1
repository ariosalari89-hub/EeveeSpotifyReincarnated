#requires -Version 7.0
param([string]$RendererPage = '')
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$page = Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html'
if ($RendererPage) { $page = $RendererPage }
$url = ([Uri](Resolve-Path $page).Path).AbsoluteUri
$session = "spicy-caption-gap-$PID"
try {
    & agent-browser --session $session open $url
    & agent-browser --session $session set viewport 340 52 | Out-Null
    Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Out-Null
    $script = @'
(async () => {
  SpicyQA.send('bootstrap',{surface:'inline',preferences:{}});
  const session=SpicyQA.observe({positionMs:5500,isPlaying:false,isPaused:true,isAdvancing:false});
  SpicyQA.send('lyrics',{state:'ready',trackId:session.trackId,generation:session.generation,data:{Type:'Line',Content:[
    {Text:'Opening phrase',StartTime:0,EndTime:1},
    {Text:'Middle verse',StartTime:4,EndTime:5},
    {Text:'Following phrase',StartTime:5.8,EndTime:7}
  ]}});
  await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame);
  const visible=[...document.querySelectorAll('.inline-visible')].map(e=>e.textContent);
  return JSON.stringify({pass:visible.length===1&&visible[0]==='Middle verse',position:5500,visible});
})()
'@
    $raw = $script | & agent-browser --session $session eval --stdin
    if ($LASTEXITCODE -ne 0) { throw "Browser evaluation failed: $raw" }
    $result = ($raw | ConvertFrom-Json) | ConvertFrom-Json
    Write-Host ($result | ConvertTo-Json -Compress)
    if (-not $result.pass) { throw 'Caption jumped to the opening phrase during a later timing gap' }
    Write-Host 'PASS caption retains current context between timed phrases'
} finally { & agent-browser --session $session close | Out-Null }
