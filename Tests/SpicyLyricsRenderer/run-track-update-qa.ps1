#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$url = ([Uri](Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html')).AbsoluteUri
$session = "spicy-track-updates-$PID"
try {
    & agent-browser --session $session open $url
    & agent-browser --session $session set viewport 393 852 | Out-Null
    Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Out-Null
    $script = @'
(async () => {
  const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  const canvas=document.createElement('canvas'); canvas.width=canvas.height=8;
  const context=canvas.getContext('2d'); context.fillStyle='#556677';context.fillRect(0,0,8,8);
  const artwork=canvas.toDataURL();
  const track={id:'qa-karaoke',title:'Stable title',artist:'Stable artist',album:'Stable album',artwork,dominantColor:'556677'};
  SpicyQA.sendSession({positionMs:6000,track}); await wait(250);
  const OriginalImage=window.Image; let images=0,mutations=0;
  window.Image=class extends OriginalImage { constructor(...args) { super(...args);images++; } };
  const observer=new MutationObserver(events=>mutations+=events.length);
  for(const id of ['title','artist','album','mini-title','mini-artist']) {
    observer.observe(document.getElementById(id),{childList:true});
  }
  try {
    for(let i=1;i<=8;i++) { SpicyQA.sendSession({positionMs:6000+i*250,track:{...track}});await wait(250); }
    observer.disconnect();
    const unchanged={images,mutations,position:Number(document.querySelector('#seek').value)};
    const changed={...track,title:'Updated title',artist:'Updated artist',album:'Updated album',dominantColor:'667788'};
    SpicyQA.sendSession({positionMs:9000,track:changed});await wait(100);
    const metadataUpdated=['title','mini-title'].every(id=>document.getElementById(id).textContent==='Updated title')
      &&['artist','mini-artist'].every(id=>document.getElementById(id).textContent==='Updated artist')
      &&document.querySelector('#album').textContent==='Updated album';
    const colorUpdated=images===unchanged.images+1;
    context.fillStyle='#aa7766';context.fillRect(0,0,8,8);changed.artwork=canvas.toDataURL();
    SpicyQA.sendSession({positionMs:9500,track:changed});await wait(100);
    const artworkUpdated=images===unchanged.images+2&&document.querySelector('#cover').src===changed.artwork
      &&document.querySelector('#mini-cover').src===changed.artwork;
    return JSON.stringify({unchanged,metadataUpdated,colorUpdated,artworkUpdated,
      pass:unchanged.images===0&&unchanged.mutations===0&&unchanged.position>=8000
        &&metadataUpdated&&colorUpdated&&artworkUpdated});
  } finally { observer.disconnect();window.Image=OriginalImage; }
})()
'@
    $raw = $script | & agent-browser --session $session eval --stdin
    if ($LASTEXITCODE -ne 0) { throw "Browser evaluation failed: $raw" }
    $result = ($raw | ConvertFrom-Json) | ConvertFrom-Json
    Write-Host ($result | ConvertTo-Json -Compress -Depth 6)
    if (-not $result.pass) { throw 'Steady playback rebuilt unchanged track presentation or real changes stopped updating' }
} finally { & agent-browser --session $session close | Out-Null }
