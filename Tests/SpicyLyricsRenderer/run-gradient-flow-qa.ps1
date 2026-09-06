#requires -Version 7.0
param([Parameter(Mandatory)][string]$EvidenceDir, [ValidateRange(1,300)][int[]]$SampleTimes = @(4,8))
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$page = Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html'
$session = "spicy-gradient-flow-$PID"
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
$EvidenceDir = (Resolve-Path $EvidenceDir).Path
function Eval-Flow([string]$script) {
    $result = $script | & agent-browser --session $session eval --stdin
    if ($LASTEXITCODE -ne 0) { throw "Gradient scenario failed: $result" }
    $result | Write-Host
}
try {
    & agent-browser --session $session open ([Uri]$page).AbsoluteUri
    & agent-browser --session $session set viewport 393 852 | Out-Null
    Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Out-Null
    Eval-Flow @'
(async () => {
  const canvas=document.createElement('canvas');canvas.width=canvas.height=128;
  const context=canvas.getContext('2d');
  ['#cc3333','#3366cc','#bb9b31','#398164'].forEach((color,index)=>{
    context.fillStyle=color;context.fillRect(index%2*64,Math.floor(index/2)*64,64,64);
  });
  const artwork=canvas.toDataURL();
  SpicyQA.tracks.karaoke.artwork=artwork;
  SpicyQA.send('bootstrap',{surface:'fullscreen',reduceMotion:false,preferences:{
    dynamicBackground:false,backgroundStyle:'gradient',backgroundSpeed:100}});
  SpicyQA.scenario('karaoke',{positionMs:7400,isPlaying:true,isPaused:false,isAdvancing:true});
  SpicyQA.sendSession({track:{...SpicyQA.tracks.karaoke,artwork},positionMs:7400,
    isPlaying:true,isPaused:false,isAdvancing:true});
  await document.fonts.ready;
  const backdrop=document.querySelector('#artwork-backdrop');
  for(const deadline=performance.now()+3000;performance.now()<deadline;){
    await new Promise(requestAnimationFrame);
    if(document.querySelector('#cover').complete && getComputedStyle(backdrop).backgroundImage!=='none')break;
  }
  // Isolate internal color motion: a rigidly transformed background cannot pass.
  backdrop.style.setProperty('transform','none','important');
  backdrop.style.setProperty('animation','none','important');
  document.querySelector('#app').style.visibility='hidden';
  await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);
  return {ready:getComputedStyle(backdrop).backgroundImage!=='none'};
})()
'@
    & agent-browser --session $session screenshot (Join-Path $EvidenceDir 'flow-0.png') | Out-Null
    Eval-Flow "SpicyQA.send('preferences',{dynamicBackground:true,backgroundStyle:'gradient',backgroundSpeed:100});true"
    $previousPhase = 0
    foreach ($phase in ($SampleTimes | Sort-Object -Unique)) {
        $remaining = ($phase - $previousPhase) * 1000
        while ($remaining -gt 0) {
            $step = [Math]::Min(10000, $remaining)
            Eval-Flow "(async()=>{const end=performance.now()+$step;while(performance.now()<end)await new Promise(requestAnimationFrame);return true;})()"
            $remaining -= $step
        }
        & agent-browser --session $session screenshot (Join-Path $EvidenceDir "flow-$phase.png") | Out-Null
        Write-Host "Captured internal gradient flow at $phase seconds"
        $previousPhase = $phase
    }
    Eval-Flow "SpicyQA.sendSession({isPlaying:false,isPaused:true,isAdvancing:false});true"
    & agent-browser --session $session screenshot (Join-Path $EvidenceDir 'paused-0.png') | Out-Null
    Eval-Flow '(async()=>{const end=performance.now()+700;while(performance.now()<end)await new Promise(requestAnimationFrame);return true;})()'
    & agent-browser --session $session screenshot (Join-Path $EvidenceDir 'paused-1.png') | Out-Null
    & agent-browser --session $session errors | Write-Host
} finally { & agent-browser --session $session close | Out-Null }
