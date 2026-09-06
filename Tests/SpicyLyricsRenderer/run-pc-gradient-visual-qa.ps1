#requires -Version 7.0
param([Parameter(Mandatory)][string]$ArtworkPath,[Parameter(Mandatory)][string]$EvidenceDir)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$page=Join-Path $repo 'layout/Library/Application Support/EeveeSpotify.bundle/SpicyLyricsRenderer/index.html'
$session="spicy-pc-gradient-visual-$PID"
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
function Eval-Gradient([string]$script) {
    $raw=$script | & agent-browser --session $session eval --stdin
    if($LASTEXITCODE-ne0){throw "Gradient visual evaluation failed: $raw"}
    return ($raw | ConvertFrom-Json) | ConvertFrom-Json
}
try {
    & agent-browser --session $session open ([Uri]$page).AbsoluteUri
    Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Out-Null
    $artwork='data:image/png;base64,'+[Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path $ArtworkPath)))
    $null=Eval-Gradient @'
(()=>{
  SpicyQA.lyrics.line.Content=[
    {Type:'Vocal',Text:'One more moment',StartTime:0,EndTime:10},
    {Type:'Vocal',Text:'Nothing fades away',StartTime:10,EndTime:18},
    {Type:'Vocal',Text:'Here until the morning',StartTime:18,EndTime:25}];
  SpicyQA.tracks.line.title='Embedded artwork';SpicyQA.tracks.line.artist='Local verification';
  SpicyQA.tracks.line.album='Illustrative lyric fixture';
  SpicyQA.send('bootstrap',{surface:'fullscreen',reduceMotion:true,preferences:{backgroundStyle:'gradient',dynamicBackground:false}});
  SpicyQA.scenario('line',{positionMs:7400,isPlaying:false,isPaused:true,isAdvancing:false});
  return JSON.stringify({ready:true});
})()
'@
    $null=Eval-Gradient "(async()=>{SpicyQA.tracks.line.artwork='$artwork';SpicyQA.sendSession({track:SpicyQA.tracks.line,positionMs:7400,isPlaying:false,isPaused:true,isAdvancing:false});await document.fonts.ready;await new Promise(r=>setTimeout(r,650));return JSON.stringify({ready:true});})()"
    $results=@()
    foreach($size in @(@(393,852),@(852,393),@(320,568),@(568,320))) {
        & agent-browser --session $session set viewport $size[0] $size[1] | Out-Null
        $result=Eval-Gradient @'
(async()=>{
  await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);
  const layer=document.querySelector('#artwork-backdrop'),canvas=layer.querySelector('canvas');
  const controls=[...document.querySelectorAll('.topbar button,.transport button,#seek-control')].map(element=>{
    const rect=element.getBoundingClientRect();return {id:element.id,x:rect.x,y:rect.y,right:rect.right,bottom:rect.bottom};});
  const outside=controls.filter(rect=>rect.x<-.5||rect.y<-.5||rect.right>innerWidth+.5||rect.bottom>innerHeight+.5);
  const veil=getComputedStyle(document.querySelector('.contrast-veil'));
  return JSON.stringify({viewport:[innerWidth,innerHeight],outside,filter:getComputedStyle(layer).filter,
    pass:!outside.length&&!canvas.hidden&&canvas.width===300&&canvas.height===150&&veil.backgroundImage==='none'
      &&veil.backgroundColor==='rgba(0, 0, 0, 0)'&&document.documentElement.scrollWidth<=innerWidth});
})()
'@
        $results+=$result
        & agent-browser --session $session screenshot (Join-Path $EvidenceDir "$($size[0])x$($size[1]).png") | Out-Null
        if(!$result.pass){throw 'PC gradient compositing or control layout failed'}
    }
    & agent-browser --session $session set viewport 393 852 | Out-Null
    & agent-browser --session $session find role button click --name 'Lyrics settings' | Out-Null
    & agent-browser --session $session screenshot (Join-Path $EvidenceDir 'settings.png') | Out-Null
    & agent-browser --session $session find role button click --name 'Close settings' | Out-Null
    $null=Eval-Gradient "(()=>{SpicyQA.send('bootstrap',{surface:'card',reduceMotion:true,preferences:{backgroundStyle:'gradient',dynamicBackground:false}});return JSON.stringify({ready:true});})()"
    & agent-browser --session $session set viewport 360 320 | Out-Null
    & agent-browser --session $session screenshot (Join-Path $EvidenceDir 'preview.png') | Out-Null
    $results | ConvertTo-Json -Depth 8 | Tee-Object -FilePath (Join-Path $EvidenceDir 'layout.json') | Write-Host
    $errors=& agent-browser --session $session errors
    if(($errors | Out-String).Trim()){throw "Browser errors: $errors"}
} finally { & agent-browser --session $session close | Out-Null }
