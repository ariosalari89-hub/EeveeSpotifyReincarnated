#requires -Version 7.0
param([Parameter(Mandatory)][string]$EvidenceDir)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$page=Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html'
$session="spicy-background-access-$PID"
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
function Eval-Access([string]$script) {
    $raw=$script | & agent-browser --session $session eval --stdin
    if($LASTEXITCODE-ne0){throw "Access evaluation failed: $raw"}
    return ($raw | ConvertFrom-Json) | ConvertFrom-Json
}
try {
    & agent-browser --session $session open ([Uri]$page).AbsoluteUri
    & agent-browser --session $session set viewport 320 568 | Out-Null
    Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Out-Null
    $null=Eval-Access "(()=>{SpicyQA.send('bootstrap',{surface:'fullscreen',reduceMotion:false,preferences:{dynamicBackground:true}});return JSON.stringify({ready:true});})()"
    & agent-browser --session $session find role button click --name 'Lyrics settings' | Out-Null
    & agent-browser --session $session snapshot -i | Write-Host
    & agent-browser --session $session press Tab | Out-Null
    & agent-browser --session $session press Tab | Out-Null
    & agent-browser --session $session press Tab | Out-Null
    $focus=Eval-Access "(()=>{const e=document.activeElement,s=getComputedStyle(e);return JSON.stringify({id:e.id,width:parseFloat(s.outlineWidth),color:s.outlineColor,visible:e.matches(':focus-visible')});})()"
    & agent-browser --session $session press ArrowDown | Out-Null
    & agent-browser --session $session press Tab | Out-Null
    & agent-browser --session $session press Tab | Out-Null
    & agent-browser --session $session press End | Out-Null
    $keyboard=Eval-Access "(()=>{const e=document.activeElement;return JSON.stringify({id:e.id,value:e.value,readout:document.querySelector('#background-speed-output').textContent,style:document.querySelector('#background-style').value});})()"
    & agent-browser --session $session screenshot (Join-Path $EvidenceDir 'keyboard-settings.png') | Out-Null
    & agent-browser --session $session press Escape | Out-Null
    $returned=Eval-Access "JSON.stringify({id:document.activeElement.id,hidden:document.querySelector('#settings-sheet').hidden,inert:document.querySelector('#app').inert})"
    & agent-browser --session $session set media dark reduced-motion | Out-Null
    $reduced=Eval-Access @'
(async()=>{
  SpicyQA.scenario('karaoke',{isPlaying:true,isPaused:false,isAdvancing:true});
  SpicyQA.send('preferences',{dynamicBackground:true,backgroundStyle:'gradient',backgroundSpeed:200});
  await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);
  const layer=document.querySelector('#artwork-backdrop');
  return JSON.stringify({media:matchMedia('(prefers-reduced-motion: reduce)').matches,
    animations:layer.getAnimations().length,disabled:document.querySelector('#background-speed').disabled,
    reasonHidden:document.querySelector('#background-motion-note').hidden});
})()
'@
    & agent-browser --session $session find role button click --name 'Lyrics settings' | Out-Null
    & agent-browser --session $session screenshot (Join-Path $EvidenceDir 'reduced-motion-settings.png') | Out-Null
    $audit=& agent-browser --session $session a11y --json
    $audit | Tee-Object -FilePath (Join-Path $EvidenceDir 'a11y.json') | Out-Null
    $result=[ordered]@{focus=$focus;keyboard=$keyboard;returned=$returned;reduced=$reduced;pass=(
        $focus.id-eq'background-style' -and $focus.visible -and $focus.width-ge2 -and
        $keyboard.id-eq'background-speed' -and $keyboard.value-eq'200' -and $keyboard.readout-eq'2×' -and $keyboard.style-eq'gradient' -and
        $returned.id-eq'settings-button' -and $returned.hidden -and !$returned.inert -and
        $reduced.media -and $reduced.animations-eq0 -and $reduced.disabled -and !$reduced.reasonHidden)}
    $result | ConvertTo-Json -Depth 8 | Tee-Object -FilePath (Join-Path $EvidenceDir 'result.json') | Write-Host
    if(!$result.pass){throw 'Background settings accessibility failed'}
    if(($audit | ConvertFrom-Json).data.violations.Count){throw 'Settings accessibility violations'}
} finally { & agent-browser --session $session close | Out-Null }
