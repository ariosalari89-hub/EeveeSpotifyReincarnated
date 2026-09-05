#requires -Version 7.0
param([switch]$ReportOnly)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$page = Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html'
$session = "spicy-transitions-$PID"
try {
    & agent-browser --session $session open ([Uri]$page).AbsoluteUri
    & agent-browser --session $session set viewport 360 320
    Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Write-Host
    Get-Content (Join-Path $PSScriptRoot 'transition-checks.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Out-Null
    $results = @()
    foreach ($phase in @('inline','card','background','highlight','card-layout')) {
        $height = if ($phase -eq 'inline') { 52 } elseif ($phase -eq 'background') { 640 } elseif ($phase -eq 'card-layout') { 392 } else { 320 }
        & agent-browser --session $session set viewport 360 $height
        $raw = "runSpicyTransitionChecks('$phase').then(JSON.stringify)" | & agent-browser --session $session eval --stdin
        if ($LASTEXITCODE -ne 0) { throw "Evaluation failed: $raw" }
        $results += ($raw | ConvertFrom-Json) | ConvertFrom-Json
    }
    foreach ($result in $results) {
        $prefix = if ($result.pass) { 'PASS' } else { 'FAIL' }
        Write-Host "$prefix $($result.name) $($result.detail | ConvertTo-Json -Depth 5 -Compress)"
    }
    $errors = & agent-browser --session $session errors
    if (($errors | Out-String).Trim()) { throw "Browser errors: $errors" }
    if (!$ReportOnly -and ($results | Where-Object { !$_.pass })) { throw 'Embedded transition checks failed' }
} finally { & agent-browser --session $session close | Out-Null }
