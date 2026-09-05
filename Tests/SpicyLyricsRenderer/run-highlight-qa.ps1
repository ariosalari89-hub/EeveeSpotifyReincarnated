#requires -Version 7.0
param([Parameter(Mandatory)][string]$EvidenceDir, [Parameter(Mandatory)][string]$ArtworkPath, [switch]$ReportOnly)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$page = Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html'
$session = "spicy-highlight-$PID"
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
function Eval-Highlight([string]$script) {
    $raw = $script | & agent-browser --session $session eval --stdin
    if ($LASTEXITCODE -ne 0) { throw "Browser evaluation failed: $raw" }
    return $raw
}
try {
    & agent-browser --session $session open ([Uri]$page).AbsoluteUri
    & agent-browser --session $session set viewport 393 852 | Out-Null
    # Recording starts a fresh document; install the fixture after that boundary.
    & agent-browser --session $session record start (Join-Path $EvidenceDir 'highlight.webm') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not start recording' }
    $null = Eval-Highlight (Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8)
    $artwork = 'data:image/jpeg;base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path $ArtworkPath)))
    $setup = @'
(async () => {
  SpicyQA.send('bootstrap',{surface:'fullscreen',preferences:{fontSize:100,dynamicBackground:false}});
  Object.assign(SpicyQA.tracks.karaoke,{title:'make you mine',artist:'Madison Beer',artwork:'ARTWORK_DATA'});
  // User-provided screenshot text and illustrative timing. Test-only content.
  SpicyQA.lyrics.karaoke.Content = [
    {Type:'Vocal',Lead:{StartTime:30,EndTime:35,Syllables:[{Text:'Can you resist?',StartTime:30,EndTime:35}]}},
    {Type:'Vocal',Lead:{StartTime:35,EndTime:45,Syllables:[{Text:"It's",StartTime:35,EndTime:37},{Text:'relentless',StartTime:37,EndTime:45}]}},
    {Type:'Vocal',Lead:{StartTime:45,EndTime:50,Syllables:[{Text:"It's why",StartTime:45,EndTime:50}]}},
    {Type:'Vocal',Lead:{StartTime:50,EndTime:56,Syllables:[{Text:'I wanna feel the rush, I wanna taste the crush',StartTime:50,EndTime:56}]}}
  ];
  SpicyQA.scenario('karaoke',{positionMs:37000,durationMs:221000,isPlaying:false,isPaused:true,isAdvancing:false});
  SpicyQA.sendSession({positionMs:37000,durationMs:221000,isPlaying:false,isPaused:true,isAdvancing:false,
    track:{id:'qa-karaoke',title:'make you mine',artist:'Madison Beer',artwork:'ARTWORK_DATA'}});
  await document.fonts.ready; await new Promise(r=>setTimeout(r,650));
  return true;
})()
'@
    $null = Eval-Highlight $setup.Replace('ARTWORK_DATA',$artwork)
    & agent-browser --session $session screenshot (Join-Path $EvidenceDir 'start.png') | Out-Null
    $null = Eval-Highlight @'
(async()=>{
  const start=performance.now();
  while(performance.now()-start<3500){
    SpicyQA.observe({positionMs:37000+performance.now()-start,durationMs:221000,isPlaying:true,isPaused:false,isAdvancing:true});
    await new Promise(r=>setTimeout(r,200));
  }
  SpicyQA.observe({positionMs:40500,durationMs:221000,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(r=>setTimeout(r,250));
  return true;
})()
'@
    & agent-browser --session $session screenshot (Join-Path $EvidenceDir 'partial.png') | Out-Null
    $null = Eval-Highlight "(async()=>{await new Promise(r=>setTimeout(r,1200));SpicyQA.observe({positionMs:44900,durationMs:221000,isPlaying:false,isPaused:true,isAdvancing:false});await new Promise(r=>setTimeout(r,250));return true;})()"
    & agent-browser --session $session screenshot (Join-Path $EvidenceDir 'end.png') | Out-Null
    $null = Eval-Highlight "new Promise(r=>setTimeout(()=>r(true),1200))"
    & agent-browser --session $session record stop | Write-Host
    if ($LASTEXITCODE -ne 0) { throw 'Could not encode the highlight recording' }
    & agent-browser --session $session a11y --json | Write-Host
    $null = Eval-Highlight (Get-Content (Join-Path $PSScriptRoot 'transition-checks.js') -Raw -Encoding utf8)
    $results = ((Eval-Highlight "runSpicyTransitionChecks('highlight').then(JSON.stringify)") | ConvertFrom-Json) | ConvertFrom-Json
    foreach ($result in $results) {
        Write-Host ($result | ConvertTo-Json -Depth 7 -Compress)
    }
    $errors = & agent-browser --session $session errors
    if (($errors | Out-String).Trim()) { throw "Browser errors: $errors" }
    if (!$ReportOnly -and ($results | Where-Object { !$_.pass })) { throw 'Fullscreen highlight paint checks failed' }
} finally { & agent-browser --session $session close | Out-Null }
