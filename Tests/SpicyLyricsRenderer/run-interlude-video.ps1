#requires -Version 7.0
param([Parameter(Mandatory)][string]$EvidenceDir)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$page = Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html'
$session = "spicy-dots-$PID"
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
function Eval-Dots([string]$script) {
    $raw = $script | & agent-browser --session $session eval --stdin
    if ($LASTEXITCODE -ne 0) { throw "Browser evaluation failed: $raw" }
    return $raw
}
try {
    & agent-browser --session $session open ([Uri]$page).AbsoluteUri
    foreach ($surface in @('fullscreen','card','inline')) {
        $height = if ($surface -eq 'inline') { 52 } elseif ($surface -eq 'card') { 320 } else { 640 }
        & agent-browser --session $session set viewport 360 $height | Out-Null
        & agent-browser --session $session record start (Join-Path $EvidenceDir "$surface.webm") | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not start recording' }
        $null = Eval-Dots (Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8)
        $null = Eval-Dots @"
(async()=>{
  SpicyQA.send('bootstrap',{surface:'$surface',preferences:{fontSize:100,dynamicBackground:false}});
  SpicyQA.lyrics.line.Content=[
    {Type:'Vocal',Text:'Stay with me',StartTime:0,EndTime:2},
    {Type:'Vocal',Text:'Here we go',StartTime:8,EndTime:11}
  ];
  Object.assign(SpicyQA.tracks.line,{title:'Interlude',artist:'Animation reference',album:''});
  SpicyQA.scenario('line',{positionMs:1000,isPlaying:false,isPaused:true,isAdvancing:false});
  await document.fonts.ready;await new Promise(r=>setTimeout(r,700));return true;
})()
"@
        & agent-browser --session $session screenshot (Join-Path $EvidenceDir "$surface-before.png") | Out-Null
        $null = Eval-Dots @'
(async()=>{
  const start=performance.now();
  while(performance.now()-start<6300){
    SpicyQA.observe({positionMs:1900+performance.now()-start,isPlaying:true,isPaused:false,isAdvancing:true});
    await new Promise(r=>setTimeout(r,200));
  }
  SpicyQA.observe({positionMs:8200,isPlaying:false,isPaused:true,isAdvancing:false});
  await new Promise(r=>setTimeout(r,700));return true;
})()
'@
        & agent-browser --session $session screenshot (Join-Path $EvidenceDir "$surface-after.png") | Out-Null
        $null = Eval-Dots 'new Promise(r=>setTimeout(()=>r(true),1000))'
        & agent-browser --session $session record stop | Write-Host
        if ($LASTEXITCODE -ne 0) { throw 'Could not encode recording' }
    }
} finally { & agent-browser --session $session close | Out-Null }
