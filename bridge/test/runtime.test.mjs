import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { runInNewContext } from 'node:vm';
import { setTimeout as delay } from 'node:timers/promises';

const bridgeFile=fileURLToPath(new URL('../pz-bridge.mjs',import.meta.url));
const clockFixture=fileURLToPath(new URL('../test-support/clock.cjs',import.meta.url));

test('pending evidence settles before cleanup and receipts retain their original identity',{timeout:8000},async t=>{
  const run=temporaryRun(t);const game=fakeGame(run);
  const origin={world:'fixture-world',actor:'0',session:'fixture-session'};
  const endpoint=await model(run,(_req,res)=>{
    game.state.actionOutcome={...origin,seq:1,action:'LOOT',status:'pending',added:0};game.publish();
    reply(res,{action:{type:'LOOT'}});
  });
  const processRun=startBridge(run,{OLLAMA_URL:endpoint.url,PZ_MAX_REQUESTS:'1'});
  await boot(processRun);await waitFor(()=>game.state.lastSeq===1,()=>processRun.output());
  await delay(350);assert.equal(run.child.exitCode,null,'bridge stopped before pending evidence settled');
  assert.equal(endpoint.calls.length,1);
  game.state.actionOutcome={...origin,seq:1,action:'LOOT',status:'observed_effect',added:1,hungerDrop:0,thirstDrop:0};game.publish();
  const[code]=await processRun.exited;assert.equal(code,0);
  const state=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(state.disarmObserved,true);assert.equal(state.outcomes.length,1);
  assert.equal(state.outcomes[0].session,origin.session);
  assert.equal(state.outcomes[0].world,origin.world);assert.equal(state.outcomes[0].actor,origin.actor);
  assert.equal(state.outcomes[0].added,1);assert.equal(state.finalObservation.session,'fixture-stopped');
});

test('unresolved existing evidence prevents a gameplay model request',{timeout:4000},async t=>{
  const run=temporaryRun(t);fakeGame(run,{actionOutcome:{seq:1,action:'DRINK',status:'pending'}});
  const endpoint=await model(run,(_req,res)=>reply(res));
  const processRun=startBridge(run,{OLLAMA_URL:endpoint.url,PZ_MAX_SECONDS:'1'});
  const[code]=await processRun.exited;assert.equal(code,0);assert.equal(endpoint.calls.length,0);
  assert.equal(fs.existsSync(path.join(run.luaDir,'claude_intent.txt')),false);
});

test('busy or unreadable action state cannot start model work or claim verified cleanup',{timeout:7000,concurrency:true},async t=>{
  await Promise.all([{qlen:-1},{qlen:null},{qlen:'0'},{nativeBusy:true},{nativeBusy:null}].map(extra=>t.test(JSON.stringify(extra),{concurrency:true},async t=>{
    const run=temporaryRun(t);fakeGame(run,extra);
    const endpoint=await model(run,(_req,res)=>reply(res));
    const processRun=startBridge(run,{OLLAMA_URL:endpoint.url,PZ_MAX_SECONDS:'1'});
    const[code]=await processRun.exited;assert.equal(code,2);assert.equal(endpoint.calls.length,0);
    const state=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
    assert.equal(state.disarmObserved,false);assert.equal(state.lab.requests,0);
    assert.equal(fs.existsSync(path.join(run.luaDir,'claude_intent.txt')),false);
  })));
});

function temporaryRun(t) {
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'pz-runtime-'));
  const luaDir=path.join(root,'Lua');fs.mkdirSync(luaDir);
  const run={root,luaDir,stateFile:path.join(root,'memory.json')};
  t.after(async()=>{
    if(run.child) {
      if(run.child.exitCode===null&&run.child.signalCode===null)run.child.kill();
      const force=setTimeout(()=>run.child.kill('SIGKILL'),4500);
      await run.exited;clearTimeout(force);
    }
    if(run.game)clearInterval(run.game.timer);
    if(run.modelServer?.listening) {
      run.modelServer.closeAllConnections();
      await new Promise((resolve,reject)=>run.modelServer.close(e=>e?reject(e):resolve()));
    }
    fs.rmSync(root,{recursive:true,force:true});
  });
  return run;
}

// Synthetic protocol peer; the actual Lua gate/body are covered separately.
function fakeGame(run,extras={}) {
  const file=path.join(run.luaDir,'claude_percept.json');
  const game={file,paused:false,offset:0,state:{labProtocol:1,session:'fixture-session',world:'fixture-world',actor:'0',
    labToken:'',armed:false,dead:false,stopFailed:false,nativeBusy:false,day:1,hour:9,hp:100,hunger:0.2,thirst:0.2,zClose:0,zNear:0,qlen:0,lastSeq:0,x:100,y:100,...extras}};
  game.publish=()=>{
    if(game.paused)return;
    const now=Date.now()+game.offset;
    try {
      const f=fs.readFileSync(path.join(run.luaDir,'claude_control.txt'),'utf8').trimEnd().split('|');
      if(f[0]==='1'&&f[1]===game.state.session&&f[2]===game.state.world&&f[3]===game.state.actor&&Number(f[7])>now) {
        if(f[5]==='ARM'){game.state.armed=true;game.state.labToken=f[4];}
        if(f[5]==='DISARM'&&f[4]===game.state.labToken){game.state.armed=false;game.state.labToken='';game.state.session='fixture-stopped';}
      }
    }catch{}
    try {
      const f=fs.readFileSync(path.join(run.luaDir,'claude_intent.txt'),'utf8').trimEnd().split('|');
      if(game.state.armed&&f.length===14&&f[8]===game.state.session&&f[9]===game.state.world
        &&f[10]===game.state.actor&&f[11]===game.state.labToken&&Number(f[13])>now&&Number(f[0])>game.state.lastSeq) {
        game.state.lastSeq=Number(f[0]);
        if(f[1]==='MOVE'){game.state.x+=Number(f[2]);game.state.y+=Number(f[3]);}
      }
    }catch{}
    game.state.observed_ms=now;fs.writeFileSync(file,JSON.stringify(game.state));
    if(game.offset){const timestamp=new Date(now);fs.utimesSync(file,timestamp,timestamp);}
  };
  game.manual=()=>{game.state.armed=false;game.state.labToken='';game.state.session='fixture-manual';game.publish();};
  game.publish();game.timer=setInterval(game.publish,40);run.game=game;return game;
}

function startBridge(run,overrides={},nodeOptions=[]) {
  // No developer credentials, HOME, provider setup, or CLI configuration inherited.
  const child=spawn(process.execPath,[...nodeOptions,bridgeFile],{cwd:run.root,env:{
    PZ_BACKEND:'ollama',PZ_MODEL:'synthetic-fixture',PZ_TIMEOUT:'2000',PZ_PORT:'0',
    PZ_LUA_DIR:run.luaDir,PZ_STATE_FILE:run.stateFile,PZ_LAB_ARM:'1',PZ_MAX_REQUESTS:'10',PZ_MAX_SECONDS:'30',...overrides,
  },stdio:['ignore','pipe','pipe']});
  let output='';child.stdout.on('data',d=>{output+=d;});child.stderr.on('data',d=>{output+=d;});
  const exited=once(child,'exit');run.child=child;run.exited=exited;
  return{child,exited,output:()=>output};
}
async function waitFor(predicate,message,timeout=10000) {
  const deadline=Date.now()+timeout;
  while(Date.now()<deadline){const result=predicate();if(result)return result;await delay(20);}
  throw new Error(message());
}
async function boot(processRun) {
  const match=await waitFor(()=>processRun.output().match(/pz-bridge up on http:\/\/([^\s/]+)\/mind/),()=>processRun.output(),3000);
  assert.match(match[1],/^127\.0\.0\.1:\d+$/);return`http://${match[1]}`;
}
function reply(res,decision={action:{type:'WAIT'},memory:'synthetic-state'}) {
  res.writeHead(200,{'content-type':'application/json',connection:'close'});
  res.end(JSON.stringify({message:{content:JSON.stringify(decision)}}));
}
async function model(run,handler) {
  const calls=[];
  const server=http.createServer(async(req,res)=>{
    const chunks=[];for await(const chunk of req)chunks.push(chunk);
    const request={url:req.url,method:req.method,body:JSON.parse(Buffer.concat(chunks).toString())};
    calls.push(request);handler(req,res,request,calls.length);
  });
  run.modelServer=server;server.listen(0,'127.0.0.1');await once(server,'listening');
  return{url:`http://127.0.0.1:${server.address().port}`,calls};
}

test('explicit lab handshake completes a synthetic model cycle with bound intent identity',{timeout:12000},async t=>{
  const run=temporaryRun(t);const game=fakeGame(run,{fixture:'isolated-runtime'});
  const endpoint=await model(run,(_req,res)=>reply(res,{action:{type:'MOVE',dx:2,dy:-1},say:'synthetic smoke',
    thought:'fixture only',goal:'temporary test run',subtask:'stay isolated',memory:'synthetic-state'}));
  const processRun=startBridge(run,{OLLAMA_URL:endpoint.url});const base=await boot(processRun);
  await waitFor(()=>fs.existsSync(run.stateFile),()=>processRun.output());
  assert.equal(endpoint.calls.length,1);assert.equal(endpoint.calls[0].url,'/api/chat');
  assert.equal(endpoint.calls[0].body.model,'synthetic-fixture');assert.match(endpoint.calls[0].body.messages[0].content,/isolated-runtime/);
  const wire=fs.readFileSync(path.join(run.luaDir,'claude_intent.txt'),'utf8');
  assert.match(wire,/^1\|MOVE\|2\|-1\|synthetic smoke\|fixture only\|stay isolated\|LAB1\|fixture-session\|fixture-world\|0\|/);
  assert.equal(wire.trimEnd().split('|').length,14);assert.equal(await(await fetch(`${base}/pz/intent`)).text(),wire);
  await waitFor(()=>game.state.lastSeq===1,()=>processRun.output());assert.equal(game.state.x,102);assert.equal(game.state.y,99);
  const state=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(state.seq,1);assert.equal(state.lab.requests,1);assert.equal(state.memory,'synthetic-state');
});

test('default monitor mode makes no provider request and writes no control or intent',{timeout:5000},async t=>{
  const run=temporaryRun(t);fakeGame(run);const endpoint=await model(run,(_req,res)=>reply(res));
  const processRun=startBridge(run,{PZ_LAB_ARM:'0',OLLAMA_URL:endpoint.url});await boot(processRun);await delay(800);
  assert.equal(endpoint.calls.length,0);assert.equal(fs.existsSync(path.join(run.luaDir,'claude_control.txt')),false);
  assert.equal(fs.existsSync(path.join(run.luaDir,'claude_intent.txt')),false);
});

test('invalid configuration exits before creating IPC or state files',{timeout:5000},async t=>{
  const run=temporaryRun(t);const processRun=startBridge(run,{PZ_PORT:'65536',OLLAMA_URL:'http://127.0.0.1:1'});
  const[code]=await processRun.exited;assert.equal(code,1);assert.match(processRun.output(),/configuration error: PZ_PORT/);
  assert.equal(fs.existsSync(run.stateFile),false);assert.deepEqual(fs.readdirSync(run.luaDir),[]);
});

test('no first percept still reaches the duration cap without a model request',{timeout:5000},async t=>{
  const run=temporaryRun(t);const endpoint=await model(run,(_req,res)=>reply(res));
  const processRun=startBridge(run,{PZ_MAX_SECONDS:'1',OLLAMA_URL:endpoint.url});
  const[code]=await processRun.exited;assert.equal(code,0);assert.equal(endpoint.calls.length,0);
  assert.match(processRun.output(),/duration_budget_exhausted/);assert.equal(fs.existsSync(path.join(run.luaDir,'claude_control.txt')),false);
});

test('legacy percept cannot arm or make a model call',{timeout:5000},async t=>{
  const run=temporaryRun(t);fakeGame(run,{labProtocol:undefined});const endpoint=await model(run,(_req,res)=>reply(res));
  const processRun=startBridge(run,{OLLAMA_URL:endpoint.url});await processRun.exited;
  assert.equal(endpoint.calls.length,0);assert.match(processRun.output(),/unsupported_or_stale_lab_protocol/);
  assert.equal(fs.existsSync(path.join(run.luaDir,'claude_intent.txt')),false);
});

test('an old percept cannot become fresh merely by starting the bridge',{timeout:5000},async t=>{
  const run=temporaryRun(t);const game=fakeGame(run);game.paused=true;
  const old=new Date(Date.now()-16000);fs.utimesSync(game.file,old,old);
  const endpoint=await model(run,(_req,res)=>reply(res));
  const processRun=startBridge(run,{OLLAMA_URL:endpoint.url,PZ_MAX_SECONDS:'1'});await processRun.exited;
  assert.equal(endpoint.calls.length,0);assert.equal(fs.existsSync(path.join(run.luaDir,'claude_control.txt')),false);
});

test('duration deadline stops a pending inference and observes disarm without publishing it',{timeout:6000},async t=>{
  const run=temporaryRun(t);fakeGame(run);const endpoint=await model(run,()=>{});
  const processRun=startBridge(run,{OLLAMA_URL:endpoint.url,PZ_MAX_SECONDS:'1'});
  const[code]=await processRun.exited;assert.equal(code,0);assert.equal(endpoint.calls.length,1);
  const state=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(state.lab.reason,'duration_budget_exhausted');assert.equal(state.disarmObserved,true);
  assert.equal(fs.existsSync(path.join(run.luaDir,'claude_intent.txt')),false);
});

test('unsafe context changes cannot publish a delayed model decision',{timeout:16000,concurrency:true},async t=>{
  const cases=[
    ['original senses expire during inference',(run,game)=>{game.offset=16000;game.publish();fs.writeFileSync(run.clockFile,'16000');}],
    ['survivor dies',(_run,game)=>{game.state.dead=true;game.publish();}],
    ['manual takeover',(_run,game)=>game.manual()],
    ['world changes',(_run,game)=>{game.state.world='other-world';game.publish();}],
    ['percept file replaced',(_run,game)=>{fs.writeFileSync(game.file+'.new',JSON.stringify(game.state));fs.renameSync(game.file+'.new',game.file);}],
    ['body becomes busy during inference',(_run,game)=>{game.state.qlen=1;game.publish();}],
    ['current percept unreadable',(_run,game)=>{game.paused=true;fs.writeFileSync(game.file,'{');}],
    ['current percept stale',(_run,game)=>{game.paused=true;const old=new Date(Date.now()-16000);fs.utimesSync(game.file,old,old);}],
  ];
  await Promise.all(cases.map(([name,invalidate])=>t.test(name,async t=>{
    const run=temporaryRun(t);run.clockFile=path.join(run.root,'clock-offset-ms');fs.writeFileSync(run.clockFile,'0');
    const game=fakeGame(run);let held;const endpoint=await model(run,(_req,res)=>{held=res;});
    const processRun=startBridge(run,{OLLAMA_URL:endpoint.url,PZ_TEST_CLOCK_FILE:run.clockFile},['--require',clockFixture]);
    await boot(processRun);await waitFor(()=>held,()=>processRun.output());invalidate(run,game);
    reply(held,{action:{type:'MOVE',dx:2,dy:0},memory:'must not be accepted',goal:'must not be accepted'});
    await waitFor(()=>/discard:|stop:/.test(processRun.output()),()=>processRun.output(),5000);
    assert.equal(endpoint.calls.length,1);assert.equal(fs.existsSync(path.join(run.luaDir,'claude_intent.txt')),false);
    if(fs.existsSync(run.stateFile)){
      const state=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
      assert.equal(state.seq,0);assert.equal(state.goal,'');assert.equal(state.memory,'(fresh mind — nothing yet)');
    }
  })));
});

test('invalid model JSON counts one attempt and has no hidden retry',{timeout:6000},async t=>{
  const run=temporaryRun(t);fakeGame(run);
  const endpoint=await model(run,(_req,res)=>{res.writeHead(200,{'content-type':'application/json',connection:'close'});res.end(JSON.stringify({message:{content:'invalid JSON'}}));});
  const processRun=startBridge(run,{OLLAMA_URL:endpoint.url,PZ_MAX_REQUESTS:'1'});const[code]=await processRun.exited;
  assert.equal(code,0);assert.equal(endpoint.calls.length,1);const state=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(state.lab.requests,1);assert.equal(state.disarmObserved,true);assert.equal(state.seq,0);
  assert.equal(fs.existsSync(path.join(run.luaDir,'claude_intent.txt')),false);
});

test('missing, unknown, or malformed actions are refused without an intent or accepted memory',{timeout:6000,concurrency:true},async t=>{
  await Promise.all([undefined,{type:'EXEC'},{type:[]},{type:'MOVE',dx:4,dy:4}].map((action,index)=>t.test(String(index),async t=>{
    const run=temporaryRun(t);fakeGame(run);
    const endpoint=await model(run,(_req,res)=>reply(res,{action,memory:'must not be saved',goal:'must not be saved'}));
    const processRun=startBridge(run,{OLLAMA_URL:endpoint.url,PZ_MAX_REQUESTS:'1'});await processRun.exited;
    assert.equal(endpoint.calls.length,1);assert.equal(fs.existsSync(path.join(run.luaDir,'claude_intent.txt')),false);
    const state=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
    assert.equal(state.seq,0);assert.equal(state.goal,'');assert.equal(state.memory,'(fresh mind — nothing yet)');
  })));
});

test('request budget stops the real bridge after two calls and observes disarm',{timeout:10000},async t=>{
  const run=temporaryRun(t);fakeGame(run);const endpoint=await model(run,(_req,res)=>reply(res));
  const processRun=startBridge(run,{OLLAMA_URL:endpoint.url,PZ_MAX_REQUESTS:'2'});const[code]=await processRun.exited;
  assert.equal(code,0);assert.equal(endpoint.calls.length,2);const state=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(state.lab.requests,2);assert.equal(state.lab.reason,'request_budget_exhausted');
  assert.equal(state.disarmObserved,true);assert.equal(state.finalObservation.armed,false);
});

test('dashboard guidance survives a discarded reply until the next accepted decision',{timeout:10000},async t=>{
  const run=temporaryRun(t);const game=fakeGame(run);const responses=[];
  const endpoint=await model(run,(_req,res)=>{responses.push(res);});const processRun=startBridge(run,{OLLAMA_URL:endpoint.url});
  const base=await boot(processRun);const guidance='synthetic guidance: stay beside the kitchen door';
  await fetch(`${base}/god?text=${encodeURIComponent(guidance)}`);const first=await waitFor(()=>responses[0],()=>processRun.output());
  fs.writeFileSync(game.file+'.new',JSON.stringify(game.state));fs.renameSync(game.file+'.new',game.file);reply(first);
  await waitFor(()=>/discard:/.test(processRun.output()),()=>processRun.output(),3000);
  const second=await waitFor(()=>responses[1],()=>processRun.output(),6000);assert.ok(JSON.stringify(endpoint.calls[1]).includes(guidance));
  reply(second,{action:{type:'WAIT'},reply:'synthetic acknowledgement',memory:'accepted guidance'});
  await waitFor(()=>fs.existsSync(path.join(run.luaDir,'claude_intent.txt')),()=>processRun.output(),3000);
  const state=await(await fetch(`${base}/api/state`)).json();assert.equal(state.seq,1);assert.equal(state.memory,'accepted guidance');
  assert.equal(state.chat.filter(item=>item.from==='claude'&&item.text==='synthetic acknowledgement').length,1);
});

test('explicit autonomous mode continues beyond ten requests and still observes cleanup',{timeout:9000},async t=>{
  const run=temporaryRun(t);const game=fakeGame(run);let firstControllerToken;
  const endpoint=await model(run,(_req,res)=>{firstControllerToken??=game.state.labToken;reply(res);});
  // Accelerate only the child process's normal four-second idle cadence. This is
  // a test preload, not a production environment override or clock change.
  const cadence='const original=globalThis.setTimeout;globalThis.setTimeout=(fn,ms,...args)=>original(fn,ms===4000?60:ms,...args);';
  const preload=`data:text/javascript,${encodeURIComponent(cadence)}`;
  const processRun=startBridge(run,{PZ_RUN_MODE:'autonomous',PZ_MAX_REQUESTS:'12',OLLAMA_URL:endpoint.url},['--import',preload]);
  const[code]=await processRun.exited;assert.equal(code,0);assert.equal(endpoint.calls.length,12);
  const state=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(state.lab.mode,'autonomous');assert.equal(state.lab.requests,12);
  assert.equal(state.run.remainingRequests,0);assert.equal(state.disarmObserved,true);
  assert.equal(state.finalObservation.armed,false);assert.equal(state.finalObservation.qlen,0);
  assert.ok(firstControllerToken?.length>16);
  for(const call of endpoint.calls){
    const prompt=call.body.messages[0].content;
    assert.equal(prompt.includes('"labToken"'),false,'controller nonce field was forwarded to the model');
    assert.equal(prompt.includes(firstControllerToken),false,'controller nonce value was forwarded to the model');
  }
});

test('dashboard exposes session limits and accepts only same-origin POST stop',{timeout:7000},async t=>{
  const run=temporaryRun(t);const game=fakeGame(run);
  const endpoint=await model(run,()=>{});
  const processRun=startBridge(run,{PZ_RUN_MODE:'autonomous',PZ_MAX_REQUESTS:'12',OLLAMA_URL:endpoint.url});
  const base=await boot(processRun);await waitFor(()=>endpoint.calls.length===1,()=>processRun.output());
  const state=await(await fetch(`${base}/api/state`)).json();
  assert.equal(state.run.mode,'autonomous');assert.equal(state.run.status,'playing');
  assert.equal(state.run.maxRequests,12);assert.equal(state.run.remainingRequests,11);
  assert.ok(state.run.remainingSeconds>0&&state.run.remainingSeconds<=30);
  assert.equal(state.percept.labToken,undefined);
  const html=await(await fetch(`${base}/mind`)).text();assert.match(html,/Stop AI/);assert.match(html,/control\/stop/);
  const payload='<img src=x onerror="stopAI()"> & \'quoted\'';
  await fetch(`${base}/god?text=${encodeURIComponent(payload)}`);
  const renderState=await(await fetch(`${base}/api/state`)).json();
  renderState.percept.health={valid:false,summary:{bleedingParts:1,glassParts:0,unknownParts:2}};
  renderState.chat.push({from:'claude',text:payload,t:'<svg/onload=stopAI()>'});
  const elements=new Map();
  const document={getElementById(id){if(!elements.has(id))elements.set(id,{});return elements.get(id);}};
  const script=html.match(/<script>([\s\S]*?)<\/script>/);assert.ok(script);
  // Execute the served render path with a small DOM stub; injected guidance and
  // model text must appear as text, never active markup in the chat container.
  await runInNewContext(script[1],{document,fetch:async()=>({json:async()=>renderState}),setInterval:()=>0});
  const rendered=elements.get('chat').innerHTML;
  assert.equal(rendered.includes('<img'),false);assert.equal(rendered.includes('<svg'),false);
  assert.ok(rendered.includes('&lt;img src=x onerror=&quot;stopAI()&quot;&gt; &amp; &#39;quoted&#39;'));
  assert.ok(rendered.includes('&lt;svg/onload=stopAI()&gt;'));
  assert.match(elements.get('health').textContent,/Body check: incomplete.*known bleeding: 1.*unknown parts: 2/);
  assert.equal((await fetch(`${base}/control/stop`)).status,405);
  assert.equal((await fetch(`${base}/control/stop`,{method:'POST'})).status,403);
  assert.equal((await fetch(`${base}/control/stop`,{method:'POST',headers:{Origin:'https://untrusted.example'}})).status,403);
  assert.equal(game.state.armed,true,'rejected stop request changed game control');
  const response=await fetch(`${base}/control/stop`,{method:'POST',headers:{Origin:base}});
  assert.equal(response.status,202);assert.deepEqual(await response.json(),{status:'stopping'});
  const[code]=await processRun.exited;assert.equal(code,0);
  const saved=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(saved.lab.reason,'dashboard_stop');assert.equal(saved.disarmObserved,true);
  assert.equal(saved.finalObservation.armed,false);assert.equal(saved.finalObservation.qlen,0);
  assert.equal(endpoint.calls.length,1);
});

test('autonomous needs guards refuse invalid or critical initial observations',{timeout:6000,concurrency:true},async t=>{
  const cases=[
    ['critical hunger',{hunger:0.85},'critical_hunger'],
    ['critical thirst',{thirst:0.65},'critical_thirst'],
    ['missing hunger',{hunger:undefined},'invalid_survivor_vitals'],
    ['string thirst',{thirst:'0.2'},'invalid_survivor_vitals'],
    ['negative need',{hunger:-0.1},'invalid_survivor_vitals'],
    ['out of range health',{hp:101},'invalid_survivor_vitals'],
  ];
  await Promise.all(cases.map(([name,change,reason])=>t.test(name,async t=>{
    const run=temporaryRun(t);fakeGame(run,change);const endpoint=await model(run,(_req,res)=>reply(res));
    const processRun=startBridge(run,{PZ_RUN_MODE:'autonomous',OLLAMA_URL:endpoint.url});
    const[code]=await processRun.exited;assert.equal(code,0);assert.equal(endpoint.calls.length,0);
    const saved=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
    assert.equal(saved.lab.reason,reason);assert.equal(saved.disarmObserved,true);
    assert.equal(fs.existsSync(path.join(run.luaDir,'claude_intent.txt')),false);
  })));
});

test('health or critical needs changes during autonomous inference stop without a late intent',{timeout:7000,concurrency:true},async t=>{
  const cases=[['health',{hp:99},'survivor_health_reduced'],['hunger',{hunger:0.85},'critical_hunger'],['thirst',{thirst:0.65},'critical_thirst']];
  await Promise.all(cases.map(([name,change,reason])=>t.test(name,async t=>{
    const run=temporaryRun(t);const game=fakeGame(run);let held;
    const endpoint=await model(run,(_req,res)=>{held=res;});
    const processRun=startBridge(run,{PZ_RUN_MODE:'autonomous',OLLAMA_URL:endpoint.url});
    await boot(processRun);await waitFor(()=>held,()=>processRun.output());
    Object.assign(game.state,change);game.publish();reply(held,{action:{type:'MOVE',dx:2,dy:0}});
    const[code]=await processRun.exited;assert.equal(code,0);assert.equal(endpoint.calls.length,1);
    const saved=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
    assert.equal(saved.lab.reason,reason);assert.equal(saved.disarmObserved,true);
    assert.equal(saved.seq,0);assert.equal(fs.existsSync(path.join(run.luaDir,'claude_intent.txt')),false);
  })));
});

test('managed startup refuses a replacement identity without touching its control',{timeout:5000},async t=>{
  const run=temporaryRun(t);fakeGame(run,{session:'replacement-session'});
  const endpoint=await model(run,(_req,res)=>reply(res));
  const processRun=startBridge(run,{PZ_RUN_MODE:'autonomous',OLLAMA_URL:endpoint.url,
    PZ_EXPECTED_SESSION:'authorized-session',PZ_EXPECTED_WORLD:'fixture-world',PZ_EXPECTED_ACTOR:'0'});
  const[code]=await processRun.exited;assert.equal(code,0);assert.equal(endpoint.calls.length,0);
  const saved=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(saved.lab.reason,'initial_session_changed');assert.equal(saved.lab.target,null);
  assert.equal(fs.existsSync(path.join(run.luaDir,'claude_control.txt')),false);
  assert.equal(fs.existsSync(path.join(run.luaDir,'claude_intent.txt')),false);
});

test('autonomous mode exits permanently after manual takeover during inference',{timeout:6000},async t=>{
  const run=temporaryRun(t);const game=fakeGame(run);
  const endpoint=await model(run,()=>{});
  const processRun=startBridge(run,{PZ_RUN_MODE:'autonomous',OLLAMA_URL:endpoint.url});
  await boot(processRun);await waitFor(()=>endpoint.calls.length===1,()=>processRun.output());
  game.manual();
  const[code]=await processRun.exited;assert.equal(code,0);assert.equal(endpoint.calls.length,1);
  const saved=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(saved.lab.reason,'game_session_changed');assert.equal(saved.disarmObserved,true);
  assert.equal(saved.finalObservation.armed,false);
  assert.equal(fs.existsSync(path.join(run.luaDir,'claude_intent.txt')),false);
  const control=fs.readFileSync(path.join(run.luaDir,'claude_control.txt'),'utf8').split('|');
  assert.equal(control[1],'fixture-session');assert.equal(control[5],'DISARM');
});

test('continuous play crosses former request and duration caps, then dashboard stop prevents late output',{timeout:15000},async t=>{
  const run=temporaryRun(t);
  const game=fakeGame(run);let held;
  const endpoint=await model(run,(_req,res,_request,count)=>{
    if(count===5){held=res;return;}
    reply(res);
  });
  // Put the counter immediately before the former request boundary and the run
  // clock beyond an hour, then cross both with real bridge HTTP decisions. The
  // pure LabRun suite separately exercises 400 sequential request increments.
  // This avoids an unrelated high-rate HTTP load test in the runtime fixture.
  const fixture=`import {LabRun} from ${JSON.stringify(new URL('../lab.mjs',import.meta.url).href)};
    const bind=LabRun.prototype.bind;
    LabRun.prototype.bind=function(...args){if(!this.fixtureElapsedHour){this.startedAt-=3601000;this.requests=300;this.fixtureElapsedHour=true;}return bind.apply(this,args);};
    const original=globalThis.setTimeout;globalThis.setTimeout=(fn,ms,...args)=>original(fn,ms===4000?5:ms,...args);`;
  const preload=`data:text/javascript,${encodeURIComponent(fixture)}`;
  const processRun=startBridge(run,{PZ_RUN_MODE:'continuous',PZ_MAX_REQUESTS:undefined,PZ_MAX_SECONDS:undefined,
    OLLAMA_URL:endpoint.url,PZ_TIMEOUT:'10000'},['--import',preload]);
  const base=await boot(processRun);await waitFor(()=>held,()=>processRun.output(),10000);
  assert.equal(run.child.exitCode,null);assert.equal(endpoint.calls.length,5);
  await waitFor(()=>game.state.lastSeq===4,()=>processRun.output());
  const state=await(await fetch(`${base}/api/state`)).json();
  assert.equal(state.run.mode,'continuous');assert.equal(state.run.requests,305);
  assert.equal(state.run.maxRequests,null);assert.equal(state.run.remainingRequests,null);
  assert.equal(state.run.maxSeconds,null);assert.equal(state.run.remainingSeconds,null);
  assert.ok(state.run.elapsedSeconds>=3600);
  const html=await(await fetch(`${base}/mind`)).text();const script=html.match(/<script>([\s\S]*?)<\/script>/);assert.ok(script);
  const elements=new Map();const document={getElementById(id){if(!elements.has(id))elements.set(id,{});return elements.get(id);}};
  await runInNewContext(script[1],{document,fetch:async()=>({json:async()=>state}),setInterval:()=>0});
  assert.match(elements.get('session').textContent,/continuous.*305 decisions.*until stopped/);
  const before=fs.readFileSync(path.join(run.luaDir,'claude_intent.txt'),'utf8');
  const stopped=await fetch(`${base}/control/stop`,{method:'POST',headers:{Origin:base}});assert.equal(stopped.status,202);
  // Resolve the pending provider reply after the explicit stop: its new state
  // and command must not be accepted even though the continuous profile has no cap.
  reply(held,{action:{type:'MOVE',dx:2,dy:0},memory:'late reply must not be saved'});
  const[code]=await processRun.exited;assert.equal(code,0);assert.equal(endpoint.calls.length,5);
  const saved=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(saved.lab.mode,'continuous');assert.equal(saved.lab.reason,'dashboard_stop');
  assert.equal(saved.lab.requests,305);assert.equal(saved.seq,4);assert.notEqual(saved.memory,'late reply must not be saved');
  assert.equal(saved.disarmObserved,true);assert.equal(saved.finalObservation.armed,false);
  assert.equal(fs.readFileSync(path.join(run.luaDir,'claude_intent.txt'),'utf8'),before);
  assert.ok(saved.log.length<=200,'continuous log retention grew beyond the cap');
});

test('continuous play continues through normal damage and critical needs but rejects invalid vitals',{timeout:7000},async t=>{
  const run=temporaryRun(t);const game=fakeGame(run);const held=[];
  const endpoint=await model(run,(_req,res)=>{held.push(res);});
  const cadence='const original=globalThis.setTimeout;globalThis.setTimeout=(fn,ms,...args)=>original(fn,ms===4000?60:ms,...args);';
  const processRun=startBridge(run,{PZ_RUN_MODE:'continuous',PZ_MAX_REQUESTS:undefined,PZ_MAX_SECONDS:undefined,
    OLLAMA_URL:endpoint.url},['--import',`data:text/javascript,${encodeURIComponent(cadence)}`]);
  const base=await boot(processRun);await waitFor(()=>held[0],()=>processRun.output());
  Object.assign(game.state,{hp:75,hunger:0.95,thirst:0.99});game.publish();reply(held[0]);
  await waitFor(()=>held[1],()=>processRun.output());
  const state=await(await fetch(`${base}/api/state`)).json();assert.equal(state.run.status,'playing');
  assert.equal(game.state.armed,true);assert.equal(game.state.lastSeq,1);
  game.state.thirst='unknown';game.publish();reply(held[1],{action:{type:'MOVE',dx:2,dy:0}});
  const[code]=await processRun.exited;assert.equal(code,0);
  const saved=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(saved.lab.reason,'invalid_survivor_vitals');assert.equal(saved.seq,1);assert.equal(saved.disarmObserved,true);
});

test('continuous mode retains permanent manual takeover and truthful disconnected dashboard status',{timeout:7000},async t=>{
  const run=temporaryRun(t);const game=fakeGame(run);const endpoint=await model(run,()=>{});
  const processRun=startBridge(run,{PZ_RUN_MODE:'continuous',PZ_MAX_REQUESTS:undefined,PZ_MAX_SECONDS:undefined,OLLAMA_URL:endpoint.url});
  const base=await boot(processRun);await waitFor(()=>endpoint.calls.length===1,()=>processRun.output());
  const html=await(await fetch(`${base}/mind`)).text();const script=html.match(/<script>([\s\S]*?)<\/script>/);assert.ok(script);
  const elements=new Map();const document={getElementById(id){if(!elements.has(id))elements.set(id,{});return elements.get(id);}};
  await runInNewContext(script[1],{document,fetch:async()=>{throw Error('connection lost');},setInterval:()=>0});
  assert.match(elements.get('session').textContent,/Connection lost.*check session status/);
  assert.equal(elements.get('stop-ai').disabled,true);
  game.manual();const[code]=await processRun.exited;assert.equal(code,0);assert.equal(endpoint.calls.length,1);
  const saved=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(saved.lab.reason,'game_session_changed');assert.equal(saved.disarmObserved,true);
  assert.equal(saved.finalObservation.armed,false);assert.equal(fs.existsSync(path.join(run.luaDir,'claude_intent.txt')),false);
});
