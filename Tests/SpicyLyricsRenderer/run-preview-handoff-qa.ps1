#requires -Version 7.0
param([Parameter(Mandatory)][string]$EvidenceDir, [string]$RendererDir)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$page = Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html'
if ($RendererDir) { $page = Join-Path (Resolve-Path $RendererDir).Path 'index.html' }
$session = "spicy-handoff-$PID"
New-Item -ItemType Directory -Path $EvidenceDir -ErrorAction Stop | Out-Null
$recording = $false
try {
    & agent-browser --session $session open ([Uri]$page).AbsoluteUri
    & agent-browser --session $session set viewport 393 360
    & agent-browser --session $session record start (Join-Path $EvidenceDir 'handoff.webm')
    $recording = $LASTEXITCODE -eq 0
    if (!$recording) { throw 'Could not record the preview handoff' }
    Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Write-Host
    @'
    document.documentElement.style.background = '#237f9d';
    SpicyQA.send('bootstrap', {surface:'card',reduceMotion:false,preferences:{fontSize:100,playbackOffset:0}});
    SpicyQA.lyrics.line.Content = Array.from({length:30},(_,i)=>({Type:'Vocal',
      Text:i===12?'The last words stay bright':i===13?'The next line takes its turn':`A preview phrase ${i}`,
      StartTime:i*2,EndTime:i*2+1.7}));
    SpicyQA.lyrics.karaoke.Content = SpicyQA.lyrics.line.Content.map(line=>({Type:'Vocal',Lead:{
      StartTime:line.StartTime,EndTime:line.EndTime,Syllables:line.Text.split(' ').map((word,i,words)=>({
        Text:word+' ',StartTime:line.StartTime+i*1.7/words.length,EndTime:line.StartTime+(i+1)*1.7/words.length
      }))}}));
    true;
'@ | & agent-browser --session $session eval --stdin | Write-Host
    foreach ($kind in @('line','karaoke')) {
        "SpicyQA.scenario('$kind',{isPaused:true,isPlaying:false,isAdvancing:false,positionMs:25650,durationMs:60000});true" | & agent-browser --session $session eval --stdin | Out-Null
        & agent-browser --session $session wait 1000 | Out-Null
        & agent-browser --session $session screenshot (Join-Path $EvidenceDir "$kind-1-active.png")
        'SpicyQA.observe({isPaused:true,isPlaying:false,isAdvancing:false,positionMs:25900,durationMs:60000});true' | & agent-browser --session $session eval --stdin | Out-Null
        & agent-browser --session $session wait 1000 | Out-Null
        & agent-browser --session $session screenshot (Join-Path $EvidenceDir "$kind-2-gap.png")
        'SpicyQA.observe({isPaused:true,isPlaying:false,isAdvancing:false,positionMs:26100,durationMs:60000});true' | & agent-browser --session $session eval --stdin | Out-Null
        & agent-browser --session $session wait 1000 | Out-Null
        & agent-browser --session $session screenshot (Join-Path $EvidenceDir "$kind-3-next.png")
    }
    $errors = & agent-browser --session $session errors
    if (($errors | Out-String).Trim()) { throw "Browser errors: $errors" }
} finally {
    $recordExit = 0
    if ($recording) {
        & agent-browser --session $session record stop | Write-Host
        $recordExit = $LASTEXITCODE
    }
    & agent-browser --session $session close | Out-Null
    if ($recordExit -ne 0) { throw 'Could not encode the preview handoff recording' }
}
