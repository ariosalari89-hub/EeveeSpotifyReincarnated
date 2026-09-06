#requires -Version 7.0
param([Parameter(Mandatory)][string]$EvidenceFile)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$page=Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html'
$session="spicy-all-transitions-$PID"
try {
    & agent-browser --session $session open ([Uri]$page).AbsoluteUri
    Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Out-Null
    Get-Content (Join-Path $PSScriptRoot 'transition-checks.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Out-Null
    $phases=@('inline','card','background','highlight','card-layout','background-style','background-speed','gradient-recovery','shuffle-availability','shuffle-settlement')
    foreach($phase in @('interlude','dot-envelope','paint','motion','emphasis','type','layout','contrast')) {
        foreach($surface in @('fullscreen','card','inline')) { $phases+="desktop-$phase-$surface" }
    }
    $phases+=@('desktop-shuffle-fullscreen','desktop-backdrop-fullscreen')
    $results=@()
    foreach($phase in $phases) {
        $height=if($phase-eq'inline'-or$phase.EndsWith('-inline')){52}elseif($phase-eq'background'-or$phase-eq'highlight'-or$phase.EndsWith('-fullscreen')-or$phase.StartsWith('background-')-or$phase.StartsWith('gradient-')-or$phase.StartsWith('shuffle-')){640}elseif($phase-eq'card-layout'){392}else{320}
        & agent-browser --session $session set viewport 360 $height | Out-Null
        $raw="runSpicyTransitionChecks('$phase').then(JSON.stringify)" | & agent-browser --session $session eval --stdin
        if($LASTEXITCODE-ne0){throw "Evaluation failed: $raw"}
        $rows=($raw | ConvertFrom-Json) | ConvertFrom-Json
        $results+=$rows
        foreach($row in $rows){Write-Host "$(if($row.pass){'PASS'}else{'FAIL'}) $($row.name)"}
    }
    $results | ConvertTo-Json -Depth 12 | Tee-Object -FilePath $EvidenceFile | Out-Null
    $errors=& agent-browser --session $session errors
    if(($errors | Out-String).Trim()){throw "Browser errors: $errors"}
    if($results | Where-Object {!$_.pass}){throw 'A shared sequential transition check failed'}
    Write-Host "PASS all $($results.Count) shared sequential checks"
} finally { & agent-browser --session $session close | Out-Null }
