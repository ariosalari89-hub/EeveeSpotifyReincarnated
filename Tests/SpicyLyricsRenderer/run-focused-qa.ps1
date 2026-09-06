#requires -Version 7.0
param([Parameter(Mandatory)][string]$Phase, [Parameter(Mandatory)][string]$EvidenceFile)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$page=Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html'
$session="spicy-focused-$PID"
try {
    & agent-browser --session $session open ([Uri]$page).AbsoluteUri
    Write-Host 'Set focused viewport'
    & agent-browser --session $session set viewport 393 852 | Out-Null
    Write-Host 'Load external playback boundary'
    Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Out-Null
    Write-Host 'Load rendered transition checks'
    Get-Content (Join-Path $PSScriptRoot 'transition-checks.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Out-Null
    Write-Host "Run $Phase"
    $quotedPhase=$Phase | ConvertTo-Json -Compress
    $raw="runSpicyTransitionChecks($quotedPhase).then(JSON.stringify)" | & agent-browser --session $session eval --stdin
    if($LASTEXITCODE-ne0){throw "Evaluation failed: $raw"}
    $rows=($raw | ConvertFrom-Json) | ConvertFrom-Json
    ConvertTo-Json -InputObject @($rows) -Depth 12 | Tee-Object -FilePath $EvidenceFile | Write-Host
    if(!$rows -or ($rows | Where-Object {!$_.pass})){throw 'A focused renderer check failed'}
    $errors=& agent-browser --session $session errors
    if(($errors | Out-String).Trim()){throw "Browser errors: $errors"}
} finally { & agent-browser --session $session close | Out-Null }
