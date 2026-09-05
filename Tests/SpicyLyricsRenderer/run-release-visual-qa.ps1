#requires -Version 7.0
param([Parameter(Mandatory)][string]$EvidenceDir, [Parameter(Mandatory)][string]$ArtworkPath)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$page = Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html'
$session = "spicy-release-visual-$PID"
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
function Eval-Visual([string]$script) {
    $raw = $script | & agent-browser --session $session eval --stdin
    if ($LASTEXITCODE -ne 0) { throw "Browser evaluation failed: $raw" }
    return ($raw | ConvertFrom-Json) | ConvertFrom-Json
}
try {
    & agent-browser --session $session open ([Uri]$page).AbsoluteUri
    & agent-browser --session $session set viewport 393 852 | Out-Null
    Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Out-Null
    $artwork = 'data:image/jpeg;base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path $ArtworkPath)))
    $null = Eval-Visual @'
(() => {
  SpicyQA.send('bootstrap',{surface:'fullscreen',preferences:{fontSize:100,dynamicBackground:false}});
  SpicyQA.lyrics.line.Content = [
    {Type:'Vocal',Text:'I wanna lay you down, I wanna string you out',StartTime:0,EndTime:57},
    {Type:'Vocal',Text:'I wanna make you mine',StartTime:57,EndTime:66},
    {Type:'Vocal',Text:'I wanna feel the rush, I wanna taste the crush',StartTime:66,EndTime:79},
    {Type:'Vocal',Text:'I wanna feel',StartTime:79,EndTime:87},
    {Type:'Vocal',Text:'I wanna lay you down',StartTime:87,EndTime:100}
  ];
  // Illustrative timing and user-supplied screenshot text; never shipped.
  SpicyQA.scenario('line',{positionMs:62000,durationMs:221000,isPlaying:false,isPaused:true,isAdvancing:false});
  return JSON.stringify({ready:true});
})()
'@
    $null = Eval-Visual "(async()=>{SpicyQA.sendSession({trackId:'qa-line',positionMs:62000,durationMs:221000,isPlaying:false,isPaused:true,isAdvancing:false,track:{id:'qa-line',title:'make you mine',artist:'Madison Beer',artwork:'$artwork'}});await document.fonts.ready;await new Promise(r=>setTimeout(r,650));return JSON.stringify({ready:true});})()"
    foreach ($size in @(@(393,852),@(852,393),@(320,568),@(568,320))) {
        & agent-browser --session $session set viewport $size[0] $size[1] | Out-Null
        $result = Eval-Visual @'
(async () => {
  await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);
  const controls = [...document.querySelectorAll('.topbar button,.transport button,#seek-control')].map(e=>{
    const r=e.getBoundingClientRect();return {id:e.id,x:r.left,y:r.top,w:r.width,h:r.height,right:r.right,bottom:r.bottom};
  });
  const outside = controls.filter(r=>r.x<-.5||r.y<-.5||r.right>innerWidth+.5||r.bottom>innerHeight+.5);
  const lyric = document.querySelector('.lyric-line.active')?.getBoundingClientRect();
  const miniWidth = document.querySelector('.mini-track').getBoundingClientRect().width;
  return JSON.stringify({viewport:[innerWidth,innerHeight],outside,controls,miniWidth,
    pass:!outside.length && lyric?.width>0 && document.documentElement.scrollWidth<=innerWidth
      && (innerHeight>=innerWidth || miniWidth>=64)});
})()
'@
        Write-Host ($result | ConvertTo-Json -Compress -Depth 5)
        & agent-browser --session $session screenshot (Join-Path $EvidenceDir "$($size[0])x$($size[1]).png") | Out-Null
        if (!$result.pass) { throw 'A playback control is clipped in the release layout' }
    }
    & agent-browser --session $session set viewport 393 852 | Out-Null
    & agent-browser --session $session find role button click --name 'Lyrics settings' | Out-Null
    & agent-browser --session $session screenshot (Join-Path $EvidenceDir 'settings.png') | Out-Null
    & agent-browser --session $session a11y --json | Write-Host
    & agent-browser --session $session find role button click --name 'Close settings' | Out-Null
    & agent-browser --session $session a11y --json | Write-Host
    & agent-browser --session $session errors | Write-Host
} finally { & agent-browser --session $session close | Out-Null }
