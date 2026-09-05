#requires -Version 7.0
param([switch]$MeasureOnly, [string]$TracePath = '')
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$url = ([Uri](Join-Path $repo 'layout\Library\Application Support\EeveeSpotify.bundle\SpicyLyricsRenderer\index.html')).AbsoluteUri
$session = "spicy-render-cost-$PID"
try {
    & agent-browser --session $session open $url
    & agent-browser --session $session set viewport 393 852 | Out-Null
    Get-Content (Join-Path $PSScriptRoot 'browser-fixture.js') -Raw -Encoding utf8 | & agent-browser --session $session eval --stdin | Out-Null
    if ($TracePath) { & agent-browser --session $session profiler start | Out-Null }
    $script = @'
(async () => {
  const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  const packet=SpicyQA.observe({positionMs:160500,durationMs:320000,isPlaying:false,isPaused:true,isAdvancing:false});
  const content=Array.from({length:80},(_,i)=>({Type:'Vocal',Lead:{StartTime:i*4,EndTime:i*4+3.5,
    Syllables:Array.from({length:10},(_,j)=>({Text:'Word'+j,StartTime:i*4+j*.35,EndTime:i*4+(j+1)*.35}))}}));
  SpicyQA.send('lyrics',{state:'ready',trackId:packet.trackId,generation:packet.generation,data:{Type:'Syllable',Content:content}});
  await wait(800);
  async function measure(name) {
    const counts={attributes:0,childList:0,characterData:0};
    const observer=new MutationObserver(events=>events.forEach(e=>counts[e.type]++));
    observer.observe(document.querySelector('#app'),{subtree:true,attributes:true,childList:true,characterData:true});
    const frames=[]; let previous=performance.now(),stopped=false;
    function frame(now) { if(stopped)return; frames.push(now-previous);previous=now;requestAnimationFrame(frame); }
    requestAnimationFrame(frame);
    const startPosition=Number(document.querySelector('#seek').value);
    const started=performance.now(); await wait(1200); stopped=true; observer.disconnect();
    frames.sort((a,b)=>a-b);
    return {name,elapsedMs:performance.now()-started,mutations:counts,
      frames:frames.length,p95FrameMs:frames[Math.floor(frames.length*.95)]||0,
      maxFrameMs:frames.at(-1)||0,active:document.querySelector('.lyric-line.active')?.dataset.index,
      advancedMs:Number(document.querySelector('#seek').value)-startPosition};
  }
  const idle=await measure('paused');
  SpicyQA.observe({positionMs:160500,durationMs:320000,isPlaying:true,isPaused:false,isAdvancing:true});
  await wait(200);
  const playing=await measure('playing');
  SpicyQA.send('lifecycle',{state:'hidden'}); await wait(300);
  const hidden=await measure('covered');
  const mutations=value=>Object.values(value.mutations).reduce((a,b)=>a+b,0);
  return JSON.stringify({idle,playing,hidden,pass:mutations(idle)<=4&&mutations(hidden)<=4
    &&playing.advancedMs>=1000&&playing.advancedMs<=1600&&playing.active==='40'
    &&idle.advancedMs===0&&hidden.advancedMs===0});
})()
'@
    $raw = $script | & agent-browser --session $session eval --stdin
    if ($LASTEXITCODE -ne 0) { throw "Browser evaluation failed: $raw" }
    $result = ($raw | ConvertFrom-Json) | ConvertFrom-Json
    Write-Host ($result | ConvertTo-Json -Compress -Depth 8)
    if ($TracePath) { & agent-browser --session $session profiler stop $TracePath | Out-Null }
    if (-not $MeasureOnly -and -not $result.pass) { throw 'Idle rendering budget or continuing playback regressed' }
} finally { & agent-browser --session $session close | Out-Null }
