#requires -Version 7.0
param([string]$Phase = 'desktop-interlude', [string[]]$Surfaces = @('fullscreen', 'card', 'inline'), [switch]$ReportOnly)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$page = Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html'
$session = "spicy-desktop-$PID"
try {
    & agent-browser --session $session open ([Uri]$page).AbsoluteUri
    Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Out-Null
    Get-Content (Join-Path $PSScriptRoot 'transition-checks.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Out-Null
    $results = @()
    foreach ($surface in $Surfaces) {
        $height = if ($surface -eq 'inline') { 52 } elseif ($surface -eq 'card') { 320 } else { 640 }
        & agent-browser --session $session set viewport 360 $height | Out-Null
        $raw = "runSpicyTransitionChecks('$Phase-$surface').then(JSON.stringify)" | & agent-browser --session $session eval --stdin
        if ($LASTEXITCODE -ne 0) { throw "Evaluation failed: $raw" }
        $results += ($raw | ConvertFrom-Json) | ConvertFrom-Json
    }
    $results | ForEach-Object { Write-Host ($_ | ConvertTo-Json -Depth 8 -Compress) }
    $errors = & agent-browser --session $session errors
    if (($errors | Out-String).Trim()) { throw "Browser errors: $errors" }
    if (!$ReportOnly -and ($results | Where-Object { !$_.pass })) { throw 'Desktop parity checks failed' }
} finally { & agent-browser --session $session close | Out-Null }
