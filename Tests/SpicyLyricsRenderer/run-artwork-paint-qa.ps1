#requires -Version 7.0
param([Parameter(Mandatory)][string]$EvidenceDir, [string]$StylesRef = '', [ValidateSet('artwork','gradient')][string]$BackgroundStyle = 'artwork')
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$page = Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html'
$session = "spicy-artwork-paint-$PID"
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
$EvidenceDir = (Resolve-Path $EvidenceDir).Path
try {
    & agent-browser --session $session open ([Uri]$page).AbsoluteUri
    Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Out-Null
    if ($StylesRef) {
        $css = & git -C $repo show "${StylesRef}:layout/Library/Application Support/EeveeSpotify.bundle/SpicyLyricsRenderer/styles.css"
        if ($LASTEXITCODE -ne 0) { throw 'Cannot read immutable comparison CSS' }
        $quoted = ($css -join "`n") | ConvertTo-Json -Compress
        "(()=>{document.querySelector('link[rel=stylesheet]').disabled=true;const s=document.createElement('style');s.textContent=$quoted;document.head.appendChild(s)})()" | & agent-browser --session $session eval --stdin | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Cannot load immutable comparison CSS' }
    }
    $results = @()
    foreach ($surface in @('fullscreen', 'card')) {
        & agent-browser --session $session set viewport 393 $(if($surface -eq 'card'){392}else{852}) | Out-Null
        foreach ($sample in @('color', 'white', 'contrast')) {
            $setup = @'
(async () => {
  const surface = 'SURFACE', sample = 'SAMPLE', backgroundStyle = 'BACKGROUND_STYLE';
  document.querySelector('#paint-hide-foreground')?.remove();
  const canvas = document.createElement('canvas'); canvas.width = canvas.height = 1024;
  const context = canvas.getContext('2d');
  context.fillStyle = sample==='color' ? '#365b87' : '#ffffff';context.fillRect(0,0,1024,1024);
  if(sample==='color'){context.fillStyle='#b96b40';context.fillRect(512,0,512,1024);}
  const artwork = canvas.toDataURL();
  SpicyQA.send('bootstrap',{surface,highContrast:sample==='contrast',reduceMotion:true,
    preferences:{fontSize:100,dynamicBackground:false,backgroundStyle}});
  SpicyQA.scenario('karaoke',{positionMs:7400,isPlaying:false,isPaused:true,isAdvancing:false});
  SpicyQA.sendSession({track:{...SpicyQA.tracks.karaoke,artwork},positionMs:7400,
    isPlaying:false,isPaused:true,isAdvancing:false});
  document.querySelector('#app').style.visibility='';
  await document.fonts.ready;
  const painted = () => {
    const background=getComputedStyle(document.querySelector('#artwork-backdrop')).backgroundImage;
    return backgroundStyle==='artwork' ? background.includes(artwork)
      : background.includes('radial-gradient') && (sample==='color'
        ? background.includes('rgb(54, 91, 135)') && background.includes('rgb(185, 107, 64)')
        : background.includes('rgb(255, 255, 255)'));
  };
  for(const deadline=performance.now()+3000;performance.now()<deadline && !painted();)
    await new Promise(requestAnimationFrame);
  if(!painted()) throw new Error('Current artwork colors not painted');
  await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);
  const rect = element => {const r=element.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height};};
  const labels=['#artist','.timeline','.brand','#mini-artist'].map(selector=>{
    const element=document.querySelector(selector),style=getComputedStyle(element);
    return {selector,color:style.color,rect:rect(element)};
  });
  return JSON.stringify({surface,sample,backgroundStyle,labels,veil:getComputedStyle(document.querySelector('.contrast-veil')).background,
    active:rect(document.querySelector('.lead.active')),filter:getComputedStyle(document.querySelector('#artwork-backdrop')).filter});
})()
'@
            $raw = $setup.Replace('SURFACE',$surface).Replace('SAMPLE',$sample).Replace('BACKGROUND_STYLE',$BackgroundStyle) | & agent-browser --session $session eval --stdin
            if ($LASTEXITCODE -ne 0) { throw "Paint setup failed: $raw" }
            $results += ($raw | ConvertFrom-Json) | ConvertFrom-Json
            & agent-browser --session $session screenshot (Join-Path $EvidenceDir "$surface-$sample.png") | Out-Null
            if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath (Join-Path $EvidenceDir "$surface-$sample.png"))) { throw 'UI screenshot missing' }
            "document.querySelector('#app').style.visibility='hidden'" | & agent-browser --session $session eval --stdin | Out-Null
            & agent-browser --session $session screenshot (Join-Path $EvidenceDir "$surface-$sample-backdrop.png") | Out-Null
            if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath (Join-Path $EvidenceDir "$surface-$sample-backdrop.png"))) { throw 'Backdrop screenshot missing' }
            @'
(() => {
  document.querySelector('#app').style.visibility='';
  const style=document.createElement('style');style.id='paint-hide-foreground';
  style.textContent='#app *{color:transparent!important;-webkit-text-fill-color:transparent!important;text-shadow:none!important}#app :is(.token,.letter,.line-text){background-image:none!important}#app :is(img,svg,input,.brand-mark,.play-button){visibility:hidden!important}';
  document.head.appendChild(style);return true;
})()
'@ | & agent-browser --session $session eval --stdin | Out-Null
            & agent-browser --session $session screenshot (Join-Path $EvidenceDir "$surface-$sample-readability.png") | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Readability background screenshot failed' }
        }
    }
    $results | ConvertTo-Json -Depth 9 | Tee-Object -FilePath (Join-Path $EvidenceDir 'paint.json') | Out-Null
    & agent-browser --session $session errors | Write-Host
    Write-Host "Captured public-renderer artwork paint in $EvidenceDir"
} finally { & agent-browser --session $session close | Out-Null }
