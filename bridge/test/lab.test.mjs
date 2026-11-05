import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { LabRun, labConfig } from '../lab.mjs';

const fixture = (extra = {}) => ({labProtocol:1,session:'session-1',world:'world-1',actor:'0',
  labToken:'test-token',armed:true,dead:false,qlen:0,stopFailed:false,observed_ms:1000000,...extra});
const run = (extra = {}) => new LabRun(labConfig({PZ_LAB_ARM:'1',...extra}),{now:()=>1000000,token:'test-token'});

test('lab defaults are monitor-only and budgets reject unsafe values',()=>{
  assert.equal(labConfig({}).arm,false);
  for(const value of ['0','11','1.5','-1',' 2','Infinity']) assert.throws(()=>labConfig({PZ_MAX_REQUESTS:value}));
  assert.throws(()=>labConfig({PZ_MAX_SECONDS:'301'}));
  assert.throws(()=>labConfig({PZ_LAB_ARM:'true'}));
  assert.equal(new LabRun(labConfig({})).beginRequest(fixture()),false);
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
  assert.match(result.stdout,/passed 25 lab Lua tests/);
});
