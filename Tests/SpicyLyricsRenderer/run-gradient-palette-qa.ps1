#requires -Version 7.0
param([Parameter(Mandatory)][string]$EvidenceDir, [switch]$MutedArtwork)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$page = Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html'
$session = "spicy-gradient-palette-$PID"
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
try {
    & agent-browser --session $session open ([Uri]$page).AbsoluteUri
    Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Out-Null
    foreach ($surface in @('fullscreen', 'card')) {
        & agent-browser --session $session set viewport 393 $(if($surface -eq 'card'){392}else{852}) | Out-Null
        $setup = @'
(async () => {
  const canvas = document.createElement('canvas'); canvas.width = canvas.height = 128;
  const context = canvas.getContext('2d');
  ['#cc3333','#3366cc','#bb9b31','#398164'].forEach((color,index)=>{
    context.fillStyle=color;context.fillRect(index%2*64,Math.floor(index/2)*64,64,64);
  });
  if (MUTED) {
    ['#080808','#363636','#646464','#929292'].forEach((color,index)=>{
      context.fillStyle=color;context.fillRect(0,index*24,128,24);
    });
    ['#cc3333','#3366cc','#bb9b31','#398164'].forEach((color,index)=>{
      context.fillStyle=color;context.fillRect(index*32,96,32,32);
    });
  }
  const artwork=canvas.toDataURL();
  SpicyQA.send('bootstrap',{surface:'SURFACE',highContrast:false,reduceMotion:true,
    preferences:{fontSize:100,dynamicBackground:false,backgroundStyle:'gradient'}});
  SpicyQA.scenario('karaoke',{positionMs:7400,isPlaying:false,isPaused:true,isAdvancing:false});
  SpicyQA.sendSession({track:{...SpicyQA.tracks.karaoke,artwork},positionMs:7400,
    isPlaying:false,isPaused:true,isAdvancing:false});
  document.querySelector('#app').style.visibility='';
  await document.fonts.ready;
  const ready=()=>document.querySelector('#cover').src===artwork && document.querySelector('#cover').complete
    && getComputedStyle(document.querySelector('#artwork-backdrop')).backgroundImage!=='none';
  for(const deadline=performance.now()+3000;performance.now()<deadline&&!ready();)
    await new Promise(requestAnimationFrame);
  if(!ready()) throw new Error('Selected cover has not painted');
  await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);
  return true;
})()
'@
        $setup.Replace('SURFACE',$surface).Replace('MUTED', $MutedArtwork.IsPresent.ToString().ToLowerInvariant()) | & agent-browser --session $session eval --stdin | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Gradient setup failed' }
        & agent-browser --session $session screenshot (Join-Path $EvidenceDir "$surface-multicolor.png") | Out-Null
        "document.querySelector('#app').style.visibility='hidden'" | & agent-browser --session $session eval --stdin | Out-Null
        & agent-browser --session $session screenshot (Join-Path $EvidenceDir "$surface-multicolor-backdrop.png") | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Gradient capture failed' }
    }
    & agent-browser --session $session errors | Write-Host
} finally { & agent-browser --session $session close | Out-Null }
