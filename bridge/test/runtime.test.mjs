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
  game.onIntent=()=>{game.state.actionOutcome={...origin,seq:1,action:'LOOT',status:'pending',added:0};};
  const endpoint=await model(run,(_req,res)=>{
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
  assert.equal(state.telemetry.counters.intentsPublished,1);
  assert.equal(state.telemetry.counters.matchedReceipts,1);
  assert.equal(state.telemetry.counters.observedEffects,1);
});

test('unresolved existing evidence prevents a gameplay model request',{timeout:4000},async t=>{
  const run=temporaryRun(t);fakeGame(run,{actionOutcome:{seq:1,action:'DRINK',status:'pending'}});
  const endpoint=await model(run,(_req,res)=>reply(res));
  const processRun=startBridge(run,{OLLAMA_URL:endpoint.url,PZ_MAX_SECONDS:'1'});
  const[code]=await processRun.exited;assert.equal(code,0);assert.equal(endpoint.calls.length,0);
  assert.equal(fs.existsSync(path.join(run.luaDir,'claude_intent.txt')),false);
});

test('survival skills retain measured outcomes through the real bridge transport',{timeout:12000},async t=>{
  await Promise.all(['DRINKTAP','FILLBOTTLE','BANDAGE','NAVIGATE'].map(type=>t.test(type,async t=>{
    const run=temporaryRun(t);const game=fakeGame(run,{water:{valid:true,sources:[{key:'100:100:0:0',reachable:true}],fillableVessels:[{key:'item:5',amount:0,capacity:2}]},
      navigation:{valid:true,scope:'current_session',world:'fixture-world',actor:'0',session:'fixture-session',anchorCount:1,
        anchors:[{id:7,x:102,y:100,z:0,canNavigate:true}]}});
    const origin={world:'fixture-world',actor:'0',session:'fixture-session'};
    game.onIntent=()=>{game.state.actionOutcome={...origin,seq:1,action:type,status:'pending',phase:type==='BANDAGE'?'bandage':'approach'};};
    const endpoint=await model(run,(_req,res)=>{
      reply(res,{action:type==='NAVIGATE'?{type,targetId:7}:{type}});
    });
    const processRun=startBridge(run,{OLLAMA_URL:endpoint.url,PZ_MAX_REQUESTS:'1'});
    await boot(processRun);await waitFor(()=>game.state.lastSeq===1,()=>processRun.output());
    const wire=fs.readFileSync(path.join(run.luaDir,'claude_intent.txt'),'utf8');
    assert.equal(wire.split('|')[1],type);assert.equal(endpoint.calls.length,1);
    assert.match(endpoint.calls[0].body.messages[0].content,/DRINKTAP.*FILLBOTTLE/s);
    if(type==='NAVIGATE'){assert.equal(wire.split('|')[2],'7');assert.equal(wire.split('|')[3],'0');game.state.x=102;}
    game.state.actionOutcome={...origin,seq:1,action:type,status:type==='NAVIGATE'?'arrived':'observed_effect',phase:'verify',
      targetId:type==='NAVIGATE'?7:0,finalX:type==='NAVIGATE'?102:100,finalY:100,finalZ:0,distanceRemaining:0,
      sourceKey:'100:100:0:0',vesselKey:type==='FILLBOTTLE'?'item:5':'',
      supplyKey:type==='BANDAGE'?'item:5':'',partIndex:type==='BANDAGE'?0:-1,bandaged:type==='BANDAGE',consumed:type==='BANDAGE',
      amountGain:type==='FILLBOTTLE'?2:0,thirstDrop:type==='DRINKTAP'?0.4:0};game.publish();
    const[code]=await processRun.exited;assert.equal(code,0);
    const state=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
    assert.equal(state.outcomes.length,1);assert.equal(state.outcomes[0].action,type);
    assert.equal(state.outcomes[0].sourceKey,'100:100:0:0');
    assert.equal(state.outcomes[0].amountGain,type==='FILLBOTTLE'?2:0);
    if(type==='BANDAGE')assert.equal(state.outcomes[0].consumed,true);
    if(type==='NAVIGATE'){assert.equal(state.outcomes[0].status,'arrived');assert.equal(state.outcomes[0].targetId,7);assert.equal(state.navigation.anchors[0].id,7);}
    assert.equal(state.telemetry.counters.matchedReceipts,1);
    assert.equal(state.telemetry.counters.observedEffects,type==='NAVIGATE'?0:1);
    assert.equal(state.telemetry.counters.arrivals,type==='NAVIGATE'?1:0);
    assert.equal(state.disarmObserved,true);
  })));
});

test('a remembered destination is revalidated after a delayed model reply',{timeout:9000,concurrency:true},async t=>{
  await Promise.all(['removed','cooldown','other namespace'].map(change=>t.test(change,async t=>{
    const run=temporaryRun(t);const game=fakeGame(run,{navigation:{valid:true,scope:'current_session',world:'fixture-world',actor:'0',session:'fixture-session',anchors:[{id:7,canNavigate:true}]}});
    let held;const endpoint=await model(run,(_req,res)=>{held=res;});
    const processRun=startBridge(run,{OLLAMA_URL:endpoint.url,PZ_MAX_REQUESTS:'1'});
    await boot(processRun);await waitFor(()=>held,()=>processRun.output());
    if(change==='removed')game.state.navigation.anchors=[];
    if(change==='cooldown')game.state.navigation.anchors[0].canNavigate=false;
    if(change==='other namespace')game.state.navigation.session='old-session';
    game.publish();reply(held,{action:{type:'NAVIGATE',targetId:7},memory:'must not be accepted'});
    const[code]=await processRun.exited;assert.equal(code,0);assert.equal(endpoint.calls.length,1);
    assert.equal(fs.existsSync(path.join(run.luaDir,'claude_intent.txt')),false);
    const saved=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));assert.equal(saved.seq,0);
    assert.equal(saved.memory,'(fresh mind — nothing yet)');
  })));
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
    labToken:'',armed:false,dead:false,stopFailed:false,nativeBusy:false,traversingWindow:false,day:1,hour:9,hp:100,hunger:0.2,thirst:0.2,zClose:0,zNear:0,qlen:0,lastSeq:0,x:100,y:100,...extras}};
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
      if(!game.holdIntent&&game.state.armed&&f.length===14&&f[8]===game.state.session&&f[9]===game.state.world
        &&f[10]===game.state.actor&&f[11]===game.state.labToken&&Number(f[13])>now&&Number(f[0])>game.state.lastSeq) {
        game.state.lastSeq=Number(f[0]);
        if(f[1]==='MOVE'){game.state.x+=Number(f[2]);game.state.y+=Number(f[3]);}
        game.onIntent?.(f);
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
function reply(res,decision={action:{type:'WAIT'},memory:'synthetic-state'},metadata={}) {
  res.writeHead(200,{'content-type':'application/json',connection:'close'});
  res.end(JSON.stringify({...metadata,message:{content:JSON.stringify(decision)}}));
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
  await waitFor(()=>game.state.lastSeq===1,()=>processRun.output());
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
    ['action evidence becomes pending during inference',(_run,game)=>{game.state.actionOutcome={seq:1,action:'DRINKTAP',status:'pending',phase:'verify'};game.publish();}],
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
  const endpoint=await model(run,(_req,res)=>{res.writeHead(200,{'content-type':'application/json',connection:'close'});res.end(JSON.stringify({model:'reported-fixture',prompt_eval_count:12,eval_count:0,message:{content:'{private-invalid-fixture-reply}'}}));});
  const processRun=startBridge(run,{OLLAMA_URL:endpoint.url,PZ_MAX_REQUESTS:'1'});const[code]=await processRun.exited;
  assert.equal(code,0);assert.equal(endpoint.calls.length,1);const state=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(state.lab.requests,1);assert.equal(state.disarmObserved,true);assert.equal(state.seq,0);
  assert.equal(fs.existsSync(path.join(run.luaDir,'claude_intent.txt')),false);
  assert.equal(state.telemetry.counters.attempts,1);assert.equal(state.telemetry.counters.responses,1);
  assert.equal(state.telemetry.counters.invalidDecisions,1);assert.equal(state.telemetry.counters.intentsPublished,0);
  assert.equal(state.telemetry.usage.inputTokens.tokens,12);assert.equal(state.telemetry.usage.outputTokens.tokens,0);
  assert.equal(state.telemetry.usage.totalTokens.tokens,null);
  assert.doesNotMatch(processRun.output()+JSON.stringify(state),/private-invalid-fixture-reply/);
});

test('model metadata survives a discarded reply without becoming game progress',{timeout:6000},async t=>{
  const run=temporaryRun(t);const game=fakeGame(run);let held;
  const endpoint=await model(run,(_req,res)=>{held=res;});
  const processRun=startBridge(run,{OLLAMA_URL:endpoint.url,PZ_MAX_REQUESTS:'1'});
  await boot(processRun);await waitFor(()=>held,()=>processRun.output());
  game.state.qlen=1;game.publish();
  reply(held,{action:{type:'WAIT'}},{model:'reported-fixture',prompt_eval_count:20,eval_count:4});
  await waitFor(()=>/discard:/.test(processRun.output()),()=>processRun.output());
  game.state.qlen=0;game.publish();await processRun.exited;
  const state=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(state.telemetry.counters.responses,1);assert.equal(state.telemetry.counters.discardedDecisions,1);
  assert.equal(state.telemetry.counters.intentsPublished,0);assert.equal(state.telemetry.counters.matchedReceipts,0);
  assert.equal(state.telemetry.usage.inputTokens.tokens,20);assert.equal(state.telemetry.usage.outputTokens.tokens,4);
});

test('publication failure records a consumed response but no command or accepted memory',{timeout:6000},async t=>{
  const run=temporaryRun(t);fakeGame(run);let held;
  const endpoint=await model(run,(_req,res)=>{held=res;});
  const processRun=startBridge(run,{OLLAMA_URL:endpoint.url,PZ_MAX_REQUESTS:'1'});
  await boot(processRun);await waitFor(()=>held,()=>processRun.output());
  fs.mkdirSync(path.join(run.luaDir,'claude_intent.txt.tmp'));
  reply(held,{action:{type:'WAIT'},memory:'must not be accepted'},{prompt_eval_count:3,eval_count:2});
  await processRun.exited;const state=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(state.telemetry.counters.responses,1);assert.equal(state.telemetry.counters.publicationFailures,1);
  assert.equal(state.telemetry.counters.intentsPublished,0);assert.equal(state.seq,0);
  assert.equal(state.memory,'(fresh mind — nothing yet)');assert.equal(state.telemetry.usage.inputTokens.tokens,3);
});

test('diagnostic failure after publication cannot report an unwritten command',{timeout:6000},async t=>{
  const run=temporaryRun(t);const game=fakeGame(run);
  const endpoint=await model(run,(_req,res)=>reply(res,{action:{type:'WAIT'},memory:'published memory'}));
  const preload=`import {RunTelemetry} from ${JSON.stringify(new URL('../telemetry.mjs',import.meta.url).href)};
    RunTelemetry.prototype.publishIntent=()=>{throw new Error('synthetic diagnostic failure');};`;
  const processRun=startBridge(run,{OLLAMA_URL:endpoint.url,PZ_MAX_REQUESTS:'1'},
    ['--import',`data:text/javascript,${encodeURIComponent(preload)}`]);
  await processRun.exited;const state=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(state.seq,1);assert.equal(game.state.lastSeq,1);assert.equal(state.memory,'published memory');
  assert.equal(state.telemetry.publicationAccountingComplete,false);
  assert.equal(state.telemetry.counters.publicationFailures,0);
  assert.match(processRun.output(),/Publication accounting incomplete; command file was written/);
  assert.doesNotMatch(processRun.output(),/intent_write_failed/);
});

test('HTTP failure has sanitized diagnostic metadata and unknown usage',{timeout:6000},async t=>{
  const run=temporaryRun(t);fakeGame(run);
  const endpoint=await model(run,(_req,res)=>{res.writeHead(429,{'x-request-id':'fixture-request-429',connection:'close'});res.end('private-provider-fixture-body');});
  const processRun=startBridge(run,{OLLAMA_URL:endpoint.url,PZ_MAX_REQUESTS:'1'});await processRun.exited;
  const state=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));const telemetry=state.telemetry;
  assert.equal(telemetry.counters.attempts,1);assert.equal(telemetry.counters.responses,0);
  assert.equal(telemetry.counters.providerFailures,1);assert.equal(telemetry.counters.invalidDecisions,0);
  assert.equal(telemetry.recentAttempts[0].metadata.httpStatus,429);
  assert.equal(telemetry.recentAttempts[0].metadata.requestId,'fixture-request-429');
  assert.equal(telemetry.usage.totalTokens.tokens,null);
  assert.doesNotMatch(processRun.output()+JSON.stringify(state),/private-provider-fixture-body/);
});

test('saved accounting and startup receipts are not attributed to a new bridge run',{timeout:6000},async t=>{
  const run=temporaryRun(t);fakeGame(run,{actionOutcome:{world:'fixture-world',actor:'0',session:'fixture-session',seq:99,action:'EAT',status:'observed_effect',hungerDrop:0.2}});
  fs.writeFileSync(run.stateFile,JSON.stringify({seq:100,telemetry:{runId:'previous-run',counters:{attempts:999,responses:999,observedEffects:999}}}));
  const endpoint=await model(run,(_req,res)=>reply(res));
  const processRun=startBridge(run,{OLLAMA_URL:endpoint.url,PZ_MAX_REQUESTS:'1'});await processRun.exited;
  const telemetry=JSON.parse(fs.readFileSync(run.stateFile,'utf8')).telemetry;
  assert.notEqual(telemetry.runId,'previous-run');assert.equal(telemetry.counters.attempts,1);
  assert.equal(telemetry.counters.responses,1);assert.equal(telemetry.counters.intentsPublished,1);
  assert.equal(telemetry.counters.matchedReceipts,0);assert.equal(telemetry.counters.observedEffects,0);
  assert.equal(telemetry.unresolvedTracked,1);assert.equal(telemetry.usage.inputTokens.tokens,null);
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
  const endpoint=await model(run,(_req,res)=>{responses.push(res);});
  const cadence='const original=setTimeout;globalThis.setTimeout=(fn,ms,...a)=>original(fn,ms===4000?100:ms,...a);';
  const processRun=startBridge(run,{OLLAMA_URL:endpoint.url},['--import',`data:text/javascript,${encodeURIComponent(cadence)}`]);
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
  renderState.percept.water={valid:false,sources:[{}],fillableVessels:[]};
  renderState.percept.actionOutcome={action:'DRINKTAP',phase:'verify',status:'unverified',detail:payload};
  renderState.chat.push({from:'claude',text:payload,t:'<svg/onload=stopAI()>'});
  renderState.telemetry.config.requestedModel=payload;
  renderState.telemetry.recentAttempts=[{metadata:{returnedModel:payload,requestId:payload,responseId:payload,httpStatus:200,latencyMs:42}}];
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
  for(const id of ['provider','model-response']){assert.equal(elements.get(id).innerHTML,undefined);assert.ok(elements.get(id).textContent.includes(payload));}
  assert.match(elements.get('activity').textContent,/Attempts 1.*responses 0.*commands published 0.*observed effects 0/);
  assert.match(elements.get('usage').textContent,/input: unknown.*0\/0 responses/);
  assert.match(elements.get('session').textContent,/model attempts/);
  assert.match(elements.get('health').textContent,/Body check: incomplete.*known bleeding: 1.*unknown parts: 2/);
  assert.equal(elements.get('water').innerHTML,undefined);
  assert.ok(elements.get('water').textContent.includes(payload));
  assert.match(elements.get('water').textContent,/Water check: incomplete.*supported sources: 1.*fillable vessels: 0/);
  renderState.percept.treatment={valid:false,eligibleWounds:[{index:0}],supplies:[{key:'item:5'}]};
  renderState.percept.actionOutcome={action:'BANDAGE',status:'unverified',detail:payload};
  await runInNewContext(script[1],{document,fetch:async()=>({json:async()=>renderState}),setInterval:()=>0});
  assert.equal(elements.get('treatment').innerHTML,undefined);
  assert.match(elements.get('treatment').textContent,/Treatment check: incomplete.*supported wounds: 1.*clean supplies: 1/);
  assert.ok(elements.get('treatment').textContent.includes(payload));
  renderState.percept.navigation={valid:true,scope:'current_session',anchorCount:1,anchors:[{id:7,room:payload,canNavigate:false,blocker:payload}]};
  renderState.percept.actionOutcome={action:'NAVIGATE',status:'unverified',detail:payload};
  await runInNewContext(script[1],{document,fetch:async()=>({json:async()=>renderState}),setInterval:()=>0});
  assert.equal(elements.get('navigation').innerHTML,undefined);
  assert.ok(elements.get('navigation').textContent.includes(payload));
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
  assert.match(elements.get('session').textContent,/continuous.*305 model attempts.*until stopped/);
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

const priorityFacts=()=>({bodyRevision:'priority-1',capabilities:{idleSelfCare:'bandage_only'},
  threats:{valid:true,status:'observed'},zTotal:0,zDist:-1,reflexed:false,traversingWindow:false,
  treatment:{valid:true,status:'observed',eligibleWounds:[{index:0,name:'Hand_L'}],
    supplies:[{key:'item:5',name:'Bandage',fullType:'Base.Bandage'}]}});
const continuous={PZ_RUN_MODE:'continuous',PZ_MAX_REQUESTS:undefined,PZ_MAX_SECONDS:undefined,PZ_TIMEOUT:'10000'};
function bandageReceipt(game,status='observed_effect',extra={}) {
  const {world,actor,session,lastSeq:seq}=game.state;
  return {world,actor,session,seq,action:'BANDAGE',status,partIndex:0,supplyKey:'item:5',
    bandaged:status==='observed_effect',consumed:status==='observed_effect',bleedingAfter:true,...extra};
}

test('local care completes during inference and fences the old model action and memory',{timeout:10000},async t=>{
  const run=temporaryRun(t);const game=fakeGame(run);let held;
  const endpoint=await model(run,(_req,res)=>{held=res;});
  const processRun=startBridge(run,{...continuous,OLLAMA_URL:endpoint.url});const base=await boot(processRun);
  await waitFor(()=>held,()=>processRun.output());
  Object.assign(game.state,priorityFacts());
  game.onIntent=()=>{game.state.actionOutcome=bandageReceipt(game,'pending');};game.publish();
  await waitFor(()=>game.state.lastSeq===1,()=>processRun.output());
  const before=fs.readFileSync(path.join(run.luaDir,'claude_intent.txt'),'utf8');assert.match(before,/^1\|BANDAGE\|/);
  game.state.actionOutcome=bandageReceipt(game);game.state.treatment.eligibleWounds=[];game.state.treatment.supplies=[];game.publish();
  await waitFor(()=>JSON.parse(fs.readFileSync(run.stateFile,'utf8')).priority.reservation===null,()=>processRun.output());
  reply(held,{action:{type:'MOVE',dx:2,dy:0},memory:'outdated memory',goal:'outdated goal',reply:'outdated reply'},
    {prompt_eval_count:23,eval_count:4});
  await waitFor(()=>JSON.parse(fs.readFileSync(run.stateFile,'utf8')).telemetry.counters.discardedDecisions===1,()=>processRun.output());
  const saved=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(saved.seq,1);assert.equal(saved.memory,'(fresh mind — nothing yet)');assert.equal(saved.goal,'');
  assert.equal(saved.chat.length,0);assert.equal(game.state.x,100);assert.equal(saved.priority.epoch,1);
  assert.equal(saved.telemetry.counters.attempts,1);assert.equal(saved.telemetry.counters.responses,1);
  assert.equal(saved.telemetry.counters.localIntentsPublished,1);assert.equal(saved.telemetry.counters.modelIntentsPublished,0);
  assert.equal(saved.telemetry.counters.matchedReceipts,1);assert.equal(saved.telemetry.usage.inputTokens.tokens,23);
  assert.equal(saved.telemetry.recentAttempts[0].reason,'local_action_superseded');
  assert.equal(fs.readFileSync(path.join(run.luaDir,'claude_intent.txt'),'utf8'),before);
  const s=await(await fetch(`${base}/api/state`)).json();const html=await(await fetch(`${base}/mind`)).text();
  assert.equal(s.lastAction,'BANDAGE (automatic care)');
  const elements=new Map();const document={getElementById(id){if(!elements.has(id))elements.set(id,{});return elements.get(id);}};
  await runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1],{document,fetch:async()=>({json:async()=>s}),setInterval:()=>0});
  assert.match(elements.get('local-care').textContent,/local commands 1.*model commands 0/);
  assert.match(elements.get('local-care').textContent,/does not establish healing or stopped bleeding/);
});

test('unacknowledged model intent reserves the slot even while the body still looks idle',{timeout:7000},async t=>{
  const run=temporaryRun(t);const game=fakeGame(run);game.holdIntent=true;
  const endpoint=await model(run,(_req,res)=>reply(res));
  const processRun=startBridge(run,{...continuous,OLLAMA_URL:endpoint.url});await boot(processRun);
  const intent=path.join(run.luaDir,'claude_intent.txt');await waitFor(()=>fs.existsSync(intent),()=>processRun.output());
  const before=fs.readFileSync(intent,'utf8');Object.assign(game.state,priorityFacts());game.publish();
  await delay(600);assert.equal(game.state.lastSeq,0);assert.equal(fs.readFileSync(intent,'utf8'),before);
  assert.equal(endpoint.calls.length,1);
  game.onIntent=f=>{if(f[1]==='BANDAGE')game.state.actionOutcome=bandageReceipt(game,'pending');};
  game.holdIntent=false;game.publish();
  await waitFor(()=>game.state.lastSeq===2,()=>processRun.output());assert.match(fs.readFileSync(intent,'utf8'),/^2\|BANDAGE\|/);
});

test('failed automatic care blocks the same pair but lets the model plan a different task',{timeout:8000},async t=>{
  const run=temporaryRun(t);const game=fakeGame(run,priorityFacts());let held;
  game.onIntent=()=>{game.state.actionOutcome=bandageReceipt(game,'pending');};
  const endpoint=await model(run,(_req,res)=>{held=res;});
  const fast='const original=setTimeout;globalThis.setTimeout=(fn,ms,...a)=>original(fn,ms===4000?100:ms,...a);';
  const processRun=startBridge(run,{...continuous,OLLAMA_URL:endpoint.url},['--import',`data:text/javascript,${encodeURIComponent(fast)}`]);
  await boot(processRun);await waitFor(()=>game.state.lastSeq===1,()=>processRun.output());
  assert.equal(endpoint.calls.length,0,'local bandage should not require a model call');
  const before=fs.readFileSync(path.join(run.luaDir,'claude_intent.txt'),'utf8');
  game.state.actionOutcome=bandageReceipt(game,'no_effect');game.publish();
  await waitFor(()=>held,()=>processRun.output());
  assert.match(endpoint.calls[0].body.messages[0].content,/LOCAL CARE:/);
  reply(held,{action:{type:'BANDAGE'},memory:'must not repeat'});
  await waitFor(()=>JSON.parse(fs.readFileSync(run.stateFile,'utf8')).telemetry.counters.discardedDecisions===1,()=>processRun.output());
  const saved=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(saved.seq,1);assert.equal(saved.telemetry.recentAttempts[0].reason,'unchanged_self_care_failure');
  assert.equal(saved.memory,'(fresh mind — nothing yet)');assert.equal(fs.readFileSync(path.join(run.luaDir,'claude_intent.txt'),'utf8'),before);
});

test('local publication failure stops without advancing epoch or counting a command',{timeout:6000},async t=>{
  const run=temporaryRun(t);const game=fakeGame(run);let held;
  const endpoint=await model(run,(_req,res)=>{held=res;});
  const processRun=startBridge(run,{...continuous,OLLAMA_URL:endpoint.url});await boot(processRun);
  await waitFor(()=>held,()=>processRun.output());fs.mkdirSync(path.join(run.luaDir,'claude_intent.txt'));
  Object.assign(game.state,priorityFacts());game.publish();
  const[code]=await processRun.exited;assert.equal(code,0);
  const saved=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(saved.lab.reason,'self_care_write_failed');assert.equal(saved.priority.epoch,0);
  assert.equal(saved.seq,0);assert.equal(saved.telemetry.counters.intentsPublished,0);assert.equal(saved.disarmObserved,true);
});

test('monitor and bounded modes never perform automatic care',{timeout:6000},async t=>{
  await Promise.all([{PZ_LAB_ARM:'0'},{PZ_RUN_MODE:'lab'},{PZ_RUN_MODE:'autonomous'}].map(overrides=>t.test(JSON.stringify(overrides),async t=>{
    const run=temporaryRun(t);fakeGame(run,priorityFacts());const endpoint=await model(run,(_req,res)=>reply(res));
    const processRun=startBridge(run,{...overrides,OLLAMA_URL:endpoint.url,PZ_MAX_SECONDS:'1'});const base=await boot(processRun);
    await delay(650);const saved=await(await fetch(`${base}/api/state`)).json();
    assert.equal(saved.priority.enabled,false);assert.equal(saved.telemetry.counters.localIntentsPublished,0);
    if(fs.existsSync(path.join(run.luaDir,'claude_intent.txt')))assert.match(fs.readFileSync(path.join(run.luaDir,'claude_intent.txt'),'utf8'),/^1\|WAIT\|/);
  })));
});

test('a post-write reservation failure stops and marks publication accounting incomplete',{timeout:6000},async t=>{
  await Promise.all(['model','self_care'].map(origin=>t.test(origin,async t=>{
    const run=temporaryRun(t);fakeGame(run,origin==='self_care'?priorityFacts():{});
    const endpoint=await model(run,(_req,res)=>reply(res));
    const preload=`import {PriorityCoordinator} from ${JSON.stringify(new URL('../priority.mjs',import.meta.url).href)};PriorityCoordinator.prototype.published=()=>false;`;
    const processRun=startBridge(run,{...continuous,OLLAMA_URL:endpoint.url},['--import',`data:text/javascript,${encodeURIComponent(preload)}`]);
    const[code]=await processRun.exited;assert.equal(code,0);
    const saved=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
    assert.equal(saved.lab.reason,'command_reservation_failed');assert.equal(saved.seq,1);
    assert.equal(saved.telemetry.publicationAccountingComplete,false);assert.equal(saved.telemetry.counters.publicationFailures,0);
    assert.equal(saved.disarmObserved,true);assert.ok(fs.existsSync(path.join(run.luaDir,'claude_intent.txt')));
  })));
});

test('regressed idle observations pause both publishers until the command sequence catches up',{timeout:6000},async t=>{
  const run=temporaryRun(t);const game=fakeGame(run);let held;
  game.onIntent=()=>{game.holdIntent=true;};
  const endpoint=await model(run,(_req,res,_body,count)=>{if(count===1)reply(res);else held=res;});
  const fast='const original=setTimeout;globalThis.setTimeout=(fn,ms,...a)=>original(fn,ms===4000?500:ms,...a);';
  const processRun=startBridge(run,{...continuous,OLLAMA_URL:endpoint.url},['--import',`data:text/javascript,${encodeURIComponent(fast)}`]);
  await boot(processRun);await waitFor(()=>game.state.lastSeq===1,()=>processRun.output());
  await waitFor(()=>JSON.parse(fs.readFileSync(run.stateFile,'utf8')).priority.reservation===null,()=>processRun.output());
  Object.assign(game.state,priorityFacts(),{lastSeq:0});game.publish();
  const intent=path.join(run.luaDir,'claude_intent.txt');const before=fs.readFileSync(intent,'utf8');
  await waitFor(()=>JSON.parse(fs.readFileSync(run.stateFile,'utf8')).priority.blocker==='sequence_regressed',()=>processRun.output());
  await delay(600);assert.equal(endpoint.calls.length,1);assert.equal(fs.readFileSync(intent,'utf8'),before);
  game.state.lastSeq=1;game.state.treatment.eligibleWounds=[];game.publish();
  await waitFor(()=>held,()=>processRun.output());assert.equal(endpoint.calls.length,2);
});

test('unexpected sequence advancement disarms and prevents pending model state acceptance',{timeout:6000},async t=>{
  const run=temporaryRun(t);const game=fakeGame(run);let held;
  const endpoint=await model(run,(_req,res,_body,count)=>{if(count===1)reply(res);else held=res;});
  const fast='const original=setTimeout;globalThis.setTimeout=(fn,ms,...a)=>original(fn,ms===4000?100:ms,...a);';
  const processRun=startBridge(run,{...continuous,OLLAMA_URL:endpoint.url},['--import',`data:text/javascript,${encodeURIComponent(fast)}`]);
  await boot(processRun);await waitFor(()=>held,()=>processRun.output());
  const intent=path.join(run.luaDir,'claude_intent.txt');const before=fs.readFileSync(intent,'utf8');
  game.state.lastSeq=99;game.publish();
  await waitFor(()=>!game.state.armed,()=>processRun.output());
  reply(held,{action:{type:'MOVE',dx:2,dy:0},memory:'foreign command must not be accepted',reply:'late reply'});
  const[code]=await processRun.exited;assert.equal(code,0);
  const saved=JSON.parse(fs.readFileSync(run.stateFile,'utf8'));
  assert.equal(saved.lab.reason,'unexpected_command_sequence');assert.equal(saved.priority.authorityFault,true);
  assert.equal(saved.disarmObserved,true);assert.equal(saved.seq,1);assert.equal(saved.memory,'synthetic-state');
  assert.equal(saved.chat.length,0);assert.equal(fs.readFileSync(intent,'utf8'),before);
});
