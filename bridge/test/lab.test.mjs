import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { LabRun, labConfig } from '../lab.mjs';

const fixture = (extra = {}) => ({labProtocol:1,session:'session-1',world:'world-1',actor:'0',
  labToken:'test-token',armed:true,dead:false,qlen:0,nativeBusy:false,stopFailed:false,observed_ms:1000000,...extra});
const run = (extra = {}) => new LabRun(labConfig({PZ_LAB_ARM:'1',...extra}),{now:()=>1000000,token:'test-token'});

test('managed starts bind the identity observed before launch and never acquire a replacement',()=>{
  assert.equal(labConfig({}).expectedIdentity,null);
  const expected={PZ_EXPECTED_SESSION:'session-1',PZ_EXPECTED_WORLD:'world-1',PZ_EXPECTED_ACTOR:'0'};
  for(const bad of [{PZ_EXPECTED_SESSION:'session-1'},{...expected,PZ_EXPECTED_ACTOR:''},
      {...expected,PZ_EXPECTED_WORLD:'invalid/world'}]) assert.throws(()=>labConfig(bad));
  const lab=run(expected);
  assert.equal(lab.bind(fixture({session:'manual-replacement'})),false);
  assert.equal(lab.reason,'initial_session_changed');
  assert.equal(lab.target,null);
  assert.equal(lab.control('DISARM'),null);
  assert.equal(run(expected).bind(fixture()),true);
});

test('lab defaults are monitor-only and budgets reject unsafe values',()=>{
  assert.deepEqual(labConfig({}),{mode:'lab',expectedIdentity:null,arm:false,maxRequests:10,maxSeconds:120});
  assert.deepEqual(labConfig({PZ_RUN_MODE:'lab',PZ_MAX_REQUESTS:'10',PZ_MAX_SECONDS:'300'}),
    {mode:'lab',expectedIdentity:null,arm:false,maxRequests:10,maxSeconds:300});
  for(const value of ['0','11','1.5','-1',' 2','Infinity']) assert.throws(()=>labConfig({PZ_MAX_REQUESTS:value}));
  assert.throws(()=>labConfig({PZ_MAX_SECONDS:'301'}));
  assert.throws(()=>labConfig({PZ_LAB_ARM:'true'}));
  assert.equal(new LabRun(labConfig({})).beginRequest(fixture()),false);
});
test('autonomous profile is explicit, bounded, and does not imply arming',()=>{
  const config=labConfig({PZ_RUN_MODE:'autonomous'});
  assert.deepEqual(config,{mode:'autonomous',expectedIdentity:null,arm:false,maxRequests:120,maxSeconds:1800});
  assert.equal(new LabRun(config).beginRequest(fixture()),false);
  assert.deepEqual(labConfig({PZ_RUN_MODE:'autonomous',PZ_LAB_ARM:'1',PZ_MAX_REQUESTS:'300',PZ_MAX_SECONDS:'3600'}),
    {mode:'autonomous',expectedIdentity:null,arm:true,maxRequests:300,maxSeconds:3600});
  for(const value of ['', 'LAB', 'CONTINUOUS', ' autonomous', 'autonomous ', null, true, 0])
    assert.throws(()=>labConfig({PZ_RUN_MODE:value}),/PZ_RUN_MODE/);
  for(const value of ['0','301','1.5','-1',' 12','Infinity'])
    assert.throws(()=>labConfig({PZ_RUN_MODE:'autonomous',PZ_MAX_REQUESTS:value}),/PZ_MAX_REQUESTS/);
  for(const value of ['0','3601','1.5','-1',' 1800','Infinity'])
    assert.throws(()=>labConfig({PZ_RUN_MODE:'autonomous',PZ_MAX_SECONDS:value}),/PZ_MAX_SECONDS/);
});
test('continuous profile is explicit, unbounded, and rejects mixed bounded configuration',()=>{
  const config=labConfig({PZ_RUN_MODE:'continuous'});
  assert.deepEqual(config,{mode:'continuous',expectedIdentity:null,arm:false,maxRequests:null,maxSeconds:null});
  assert.equal(new LabRun(config).beginRequest(fixture()),false);
  assert.equal(labConfig({PZ_RUN_MODE:'continuous',PZ_LAB_ARM:'1'}).arm,true);
  for(const name of ['PZ_MAX_REQUESTS','PZ_MAX_SECONDS']) {
    for(const value of ['10','1800','0','',null]) {
      assert.throws(()=>labConfig({PZ_RUN_MODE:'continuous',[name]:value}),/Continuous mode does not accept/);
    }
  }
});
test('continuous sessions exceed three hundred requests and one hour but retain short command leases',()=>{
  let time=1000000;
  const lab=new LabRun(labConfig({PZ_RUN_MODE:'continuous',PZ_LAB_ARM:'1'}),
    {now:()=>time,token:'test-token'});
  for(let i=0;i<400;i++) {
    time+=10000;
    const current=fixture({observed_ms:time});
    assert.equal(lab.beginRequest(current),true);
    assert.equal(lab.expired(),false);
    assert.equal(Number(lab.control().split('|')[7]),time+2000);
    assert.equal(Number(lab.intent(current,i+1,{type:'WAIT'}).split('|')[13]),time+2000);
  }
  assert.equal(lab.requests,400);
  assert.ok(time-lab.startedAt>3600000);
  assert.deepEqual(lab.target,{session:'session-1',world:'world-1',actor:'0'});
  assert.equal(lab.snapshot().mode,'continuous');
  assert.equal(lab.snapshot().maxRequests,null);
  assert.equal(lab.snapshot().maxSeconds,null);
  assert.equal(Number(lab.control('DISARM').split('|')[7]),time+2000);
});
test('continuous mode preserves death, manual disarm, identity and explicit-stop guards',()=>{
  for(const change of [{dead:true},{armed:false},{labToken:'replacement'},{observed_ms:996000}]) {
    const lab=run({PZ_RUN_MODE:'continuous'});
    assert.equal(lab.beginRequest(fixture(change)),false);
    assert.equal(lab.requests,0);
  }
  for(const key of ['session','world','actor']) {
    const lab=run({PZ_RUN_MODE:'continuous'});
    assert.equal(lab.beginRequest(fixture()),true);
    assert.equal(lab.beginRequest(fixture({[key]:'replacement'})),false);
    assert.equal(lab.reason,'game_session_changed');
    assert.equal(lab.beginRequest(fixture()),false);
    assert.equal(lab.requests,1);
  }
  const lab=run({PZ_RUN_MODE:'continuous'});
  assert.equal(lab.beginRequest(fixture()),true);
  lab.stop('manual_stop');
  assert.equal(lab.beginRequest(fixture()),false);
  assert.equal(lab.requests,1);
});
test('autonomous session continues past ten requests under the same binding and stops at its cap',()=>{
  const lab=run({PZ_RUN_MODE:'autonomous',PZ_MAX_REQUESTS:'12'});
  for(let i=0;i<12;i++) assert.equal(lab.beginRequest(fixture()),true);
  assert.equal(lab.requests,12);
  assert.deepEqual(lab.target,{session:'session-1',world:'world-1',actor:'0'});
  assert.equal(lab.snapshot().mode,'autonomous');
  assert.equal(lab.beginRequest(fixture()),false);
  assert.equal(lab.reason,'request_budget_exhausted');
  assert.equal(lab.beginRequest(fixture()),false);
  assert.equal(lab.requests,12);
});
test('autonomous profile cannot replace a revoked identity or restart after an explicit stop',()=>{
  for(const key of ['session','world','actor']) {
    const lab=run({PZ_RUN_MODE:'autonomous'});
    assert.equal(lab.beginRequest(fixture()),true);
    assert.equal(lab.beginRequest(fixture({[key]:'replacement'})),false);
    assert.equal(lab.reason,'game_session_changed');
    assert.equal(lab.beginRequest(fixture()),false);
    assert.equal(lab.requests,1);
    assert.equal(lab.target[key],fixture()[key]);
  }
  const lab=run({PZ_RUN_MODE:'autonomous'});
  assert.equal(lab.beginRequest(fixture()),true);
  assert.equal(lab.beginRequest(fixture({armed:false})),false);
  lab.stop('manual_stop');
  assert.equal(lab.beginRequest(fixture()),false);
  assert.equal(lab.requests,1);
});
test('longer autonomous duration still clamps leases and expires without extending itself',()=>{
  let time=1000000;
  const lab=new LabRun(labConfig({PZ_RUN_MODE:'autonomous',PZ_LAB_ARM:'1',PZ_MAX_SECONDS:'3600'}),
    {now:()=>time,token:'test-token'});
  lab.bind(fixture());time+=3599000;
  assert.equal(lab.control().split('|')[7],'4600000');
  time+=1000;assert.equal(lab.expired(),true);
  assert.equal(lab.beginRequest(fixture({observed_ms:time})),false);
  assert.equal(lab.requests,0);
  assert.equal(lab.control('DISARM').split('|')[7],'4602000');
});
test('attempts are counted before success and cannot exceed the cap',()=>{
  const lab=run();
  for(let i=0;i<10;i++) assert.equal(lab.beginRequest(fixture()),true);
  assert.equal(lab.requests,10);
  assert.equal(lab.beginRequest(fixture()),false);
  assert.equal(lab.reason,'request_budget_exhausted');
});
test('session, world, actor, stale senses, and token mismatch prevent decisions',()=>{
  for(const key of ['session','world','actor']) {
    const lab=run(); assert.equal(lab.beginRequest(fixture()),true);
    assert.equal(lab.beginRequest(fixture({[key]:'changed'})),false);
    assert.equal(lab.reason,'game_session_changed');
  }
  for(const change of [{armed:false},{labToken:'someone-else'},{observed_ms:996000},{observed_ms:1001000},{dead:true},{labProtocol:undefined}]) {
    assert.equal(run().beginRequest(fixture(change)),false);
  }
});
test('wire binds full identity and rejects oversized/coerced moves',()=>{
  const lab=run();lab.bind(fixture());
  for(const action of [{type:'MOVE',dx:4,dy:4},{type:'MOVE',dx:'1',dy:0},{type:'MOVE',dx:0,dy:0}])
    assert.throws(()=>lab.intent(fixture(),1,action));
  const wire=lab.intent(fixture(),1,{type:'MOVE',dx:2,dy:-1});
  assert.equal(wire.split('|').length,14);
  assert.match(wire,/\|LAB1\|session-1\|world-1\|0\|test-token\|1000000\|1002000$/);
});
test('lifetime starts before first percept and cannot be extended by heartbeats',()=>{
  let time=1000000;
  const lab=new LabRun(labConfig({PZ_LAB_ARM:'1',PZ_MAX_SECONDS:'1'}),{now:()=>time,token:'test-token'});
  lab.bind(fixture());time+=900;
  assert.equal(lab.control().split('|')[7],'1001000');
  time+=100;assert.equal(lab.expired(),true);
  assert.equal(lab.beginRequest(fixture({observed_ms:time})),false);
  assert.equal(lab.control('DISARM').split('|')[7],'1003000');
});
test('cleanup requires matching original world and actor, an empty queue, and no stop failure',()=>{
  const lab=run();lab.bind(fixture());
  assert.equal(lab.disarmObserved(fixture({armed:false,session:'rotated-session'}),1000000),true);
  for(const change of [{world:'replacement'},{actor:'2'},{qlen:1},{stopFailed:true},{observed_ms:999999}])
    assert.equal(lab.disarmObserved(fixture({armed:false,...change}),1000000),false);
});
test('Lua lab gate and actual body entry point enforce takeover',t=>{
  const script=fileURLToPath(new URL('../test-support/lab-control.lua',import.meta.url));
  const directory=fileURLToPath(new URL('../../mods/ClaudeSurvivor/42/media/lua/client',import.meta.url));
  const result=spawnSync('lua',[script,directory],{encoding:'utf8',timeout:5000});
  if(result.error?.code==='ENOENT') { t.skip('Lua is not installed; gate engine stubs were not run.');return; }
  assert.equal(result.status,0,`${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout,/passed 32 lab Lua tests/);
});
