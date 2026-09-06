#requires -Version 7.0
param([Parameter(Mandatory)][string]$EvidenceDir, [Parameter(Mandatory)][string]$ArtworkPath)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$page=Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html'
$session="spicy-background-video-$PID"
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
$EvidenceDir=(Resolve-Path $EvidenceDir).Path
$artwork='data:image/jpeg;base64,'+[Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path $ArtworkPath)))
function Eval-Motion([string]$script) {
    $raw=$script | & agent-browser --session $session eval --stdin
    if($LASTEXITCODE-ne0){throw "Motion evaluation failed: $raw"}
    return ($raw | ConvertFrom-Json) | ConvertFrom-Json
}
try {
    & agent-browser --session $session open ([Uri]$page).AbsoluteUri
    $results=@()
    foreach($style in @('artwork','gradient')) {
        & agent-browser --session $session set viewport 393 852 | Out-Null
        & agent-browser --session $session record start (Join-Path $EvidenceDir "$style.webm") | Out-Null
        if($LASTEXITCODE-ne0){throw 'Motion recording did not start'}
        # Recording starts a fresh context; reinstall only the public fixture.
        & agent-browser --session $session set viewport 393 852 | Out-Null
        Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Out-Null
        $null=Eval-Motion @"
(async()=>{
  SpicyQA.send('bootstrap',{surface:'fullscreen',reduceMotion:false,preferences:{fontSize:100,dynamicBackground:true,backgroundStyle:'$style',backgroundSpeed:100}});
  SpicyQA.lyrics.line.Content=[
    {Type:'Vocal',Text:'I wanna lay you down, I wanna string you out',StartTime:0,EndTime:57},
    {Type:'Vocal',Text:'I wanna make you mine',StartTime:57,EndTime:66},
    {Type:'Vocal',Text:'I wanna feel the rush, I wanna taste the crush',StartTime:66,EndTime:79},
    {Type:'Vocal',Text:'I wanna feel',StartTime:79,EndTime:87}
  ];
  SpicyQA.scenario('line',{positionMs:62000,durationMs:221000,isPlaying:true,isPaused:false,isAdvancing:true});
  SpicyQA.sendSession({track:{id:'qa-line',title:'make you mine',artist:'Madison Beer',artwork:'$artwork',dominantColor:''},positionMs:62000,durationMs:221000,isPlaying:true,isPaused:false,isAdvancing:true});
  await document.fonts.ready;
  const layer=document.querySelector('#artwork-backdrop');
  for(const deadline=performance.now()+3000;performance.now()<deadline && !layer.classList.contains('is-animated');)await new Promise(requestAnimationFrame);
  if(!layer.classList.contains('is-animated'))throw new Error('Current cover motion did not start');
  return JSON.stringify({ready:true});
})()
"@
        foreach($rate in @(100,200,25,0)) {
            if($rate-ne100) {
                & agent-browser --session $session find role button click --name 'Lyrics settings' | Out-Null
                if($rate-eq0) { & agent-browser --session $session uncheck '#background-toggle' | Out-Null }
                else {
                    & agent-browser --session $session focus '#background-speed' | Out-Null
                    & agent-browser --session $session press $(if($rate-eq200){'End'}else{'Home'}) | Out-Null
                }
                & agent-browser --session $session find role button click --name 'Close settings' | Out-Null
            }
            $row=Eval-Motion @"
(async()=>{
  const layer=document.querySelector('#artwork-backdrop');await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);
  const start=getComputedStyle(layer).transform,times=[],started=performance.now();let previous=started;
  for(const deadline=started+3000;performance.now()<deadline;){await new Promise(requestAnimationFrame);const now=performance.now();times.push(now-previous);previous=now;}
  const end=getComputedStyle(layer).transform,animation=layer.getAnimations()[0];times.sort((a,b)=>a-b);
  const rate=animation?.playbackRate,playing=animation?.playState==='running';
  return JSON.stringify({style:'$style',requested:$rate,start,end,rate,playing,
    frames:times.length,medianFrameMs:times[Math.floor(times.length*.5)],p95FrameMs:times[Math.floor(times.length*.95)],
    pass:$rate===0 ? start===end && !playing : start!==end && playing && rate===$rate/100});
})()
"@
            $results+=$row
            Write-Host ($row | ConvertTo-Json -Compress -Depth 5)
            $results | ConvertTo-Json -Depth 8 | Tee-Object -FilePath (Join-Path $EvidenceDir 'motion.json') | Out-Null
            & agent-browser --session $session screenshot (Join-Path $EvidenceDir "$style-$rate.png") | Out-Null
        }
        & agent-browser --session $session record stop | Out-Null
        if($LASTEXITCODE-ne0){throw 'Motion recording did not save'}
        $errors=& agent-browser --session $session errors
        if(($errors | Out-String).Trim()){throw "Browser errors: $errors"}
    }
    $results | ConvertTo-Json -Depth 8 | Tee-Object -FilePath (Join-Path $EvidenceDir 'motion.json') | Out-Null
    if($results | Where-Object {!$_.pass}){throw 'A recorded background-motion check failed'}
} finally { & agent-browser --session $session close | Out-Null }
