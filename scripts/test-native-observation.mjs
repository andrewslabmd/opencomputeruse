import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { performance } from 'node:perf_hooks';
import { parse } from 'yaml';
import { Client } from '../packages/cli/client.mjs';
if (!process.argv.includes('--interactive')) throw new Error('Live native observation tests require explicit --interactive authorization');
const base=resolve('work/native-observation-'+Date.now());
await mkdir(base,{recursive:true});
execFileSync('xcrun',['swiftc','-parse-as-library','tests/native-fixtures/ObservationFixture.swift','-o',join(base,'ObservationFixture')]);
const client=new Client(), control=new Client();
const results=[]; let fixture;
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const decode=r=>{assert.notEqual(r.isError,true);return parse(r.content.find(x=>x.type==='text').text)};
const nodes=s=>s.surface.windows.flatMap(w=>{const list=[],stack=[w.tree];while(stack.length){const n=stack.pop();list.push(n);stack.push(...(n.children??[]));}return list;});
async function start(mode){
 fixture=spawn(join(base,'ObservationFixture'),[mode,join(base,mode+'-state.json')],{stdio:'ignore'});
 const by=Date.now()+10000;
 while(true){try{const j=JSON.parse(await readFile(join(base,mode+'-state.json')));if(j.pid===fixture.pid)return;}catch{}assert.ok(fixture.exitCode===null&&Date.now()<by);await sleep(50)}
}
async function dispose(){
 await client.request('release').catch(()=>{});
 if(fixture&&fixture.exitCode===null){fixture.kill('SIGTERM');await new Promise(r=>fixture.once('exit',r));}
 fixture=null;
}
const observe=async title=>decode(await client.request('tools/call',{name:'use_observe',arguments:{app_target:'PID:'+fixture.pid,window_title:title}})).snapshot;
const batch=async actions=>decode(await client.request('tools/call',{name:'use_action_batch',arguments:{actions}}));
const point=n=>({x:n.frame.x+n.frame.width/2,y:n.frame.y+n.frame.height/2});
try{
 await client.connect('Shared observation acceptance'); await control.connect('Responsive control acceptance');
 const host=await control.request('status');assert.ok(!host.busy&&!host.paused&&!host.owner);
 for(const mode of ['close-exit','close-stay','button-exit','button-accepted-exit']){
  await start(mode);const pid=fixture.pid;const before=await observe('OCU observation '+mode);
  const target=nodes(before).find(n=>mode.startsWith('button-')?n.name==='Finish fixture':n.subrole==='AXCloseButton');assert.ok(target);
  const actions=[{kind:'click',at:point(target)},...(mode==='button-accepted-exit'?[{kind:'wait',milliseconds:1000},{kind:'hotkey',keys:['right']}]:[])];
  const result=await batch(actions);await writeFile(join(base,mode+'-result.json'),JSON.stringify(result,null,2));
  if(mode==='button-exit'){const operation=result.actions[0].native_operations.find(o=>o.name==='AXPress');assert.ok(operation);if(operation.outcome==='returned_error'){assert.equal(result.actions[0].status,'failed');assert.equal(result.actions[0].code,'native_operation_uncertain');}else if(operation.outcome==='accepted'){assert.equal(result.actions[0].status,'completed');}else{assert.equal(result.actions[0].status,'pending');}}else{assert.equal(result.actions[0].status,'completed');assert.ok(!result.actions[0].code);}assert.ok(!result.actions[0].observation_error);
  if(mode==='close-stay'){
    assert.equal(result.status,'completed');assert.ok(result.snapshot.surface.closed_window_id || result.snapshot.surface.unavailable_window_id);assert.equal(result.snapshot.surface.available,false);assert.equal(result.snapshot.application.state,undefined);
    assert.equal(fixture.exitCode,null);
  } else {
    assert.equal(result.snapshot.application.state,'exited');assert.equal(result.snapshot.surface.available,false);
    assert.equal(result.status,mode==='button-accepted-exit'||['failed','pending'].includes(result.actions[0].status)?'stopped':'completed');assert.equal(result.actions.length,mode==='button-accepted-exit'?2:1);
    const by=Date.now()+5000;while(fixture.exitCode===null&&Date.now()<by)await sleep(25);assert.notEqual(fixture.exitCode,null);
  }
  results.push({mode,pid,status:result.status,action_status:result.actions[0].status,process_state:result.snapshot.application.state??'running',passed:true});
  await dispose();
 }
 await start('close-stay');const unscoped=await observe();
 const lastClose=nodes(unscoped).find(n=>n.subrole==='AXCloseButton');assert.ok(lastClose);
 const lastClosed=await batch([{kind:'click',element:lastClose.id}]);
 assert.equal(lastClosed.status,'completed');assert.equal(lastClosed.actions[0].status,'completed');assert.ok(!lastClosed.actions[0].observation_error);
 assert.equal(lastClosed.snapshot.surface.available,false);assert.equal(lastClosed.snapshot.application.state,undefined);assert.equal(lastClosed.snapshot.surface.window_count,0);
 assert.ok(lastClosed.actions[0].observed_changes.items.some(c=>c.property==='window'&&c.after==='not_observable'));
 await writeFile(join(base,'close-stay-unscoped-result.json'),JSON.stringify(lastClosed,null,2));
 results.push({mode:'close-stay-unscoped',passed:true});await dispose();
 await start('text-style');const styled=await observe('OCU observation text-style');const style=nodes(styled).flatMap(n=>n.selection_style??[]);assert.ok(style.some(r=>r.location===6&&r.length===6&&r.underline===true&&r.strikethrough===true));await writeFile(join(base,'text-style-result.json'),JSON.stringify(styled,null,2));results.push({mode:'text-style',style,passed:true});await dispose();
 await start('large');let begin=performance.now();const large=await observe();const duration=performance.now()-begin;
 await writeFile(join(base,'large-result.json'),JSON.stringify(large,null,2));
 const all=nodes(large);assert.ok(large.node_count>6500);assert.equal(large.surface.window_count,2);
 assert.ok(all.some(n=>n.name==='Owned content 6499'));assert.equal(all.filter(n=>n.subrole==='AXCloseButton').length,2);
 results.push({mode:'large',node_count:large.node_count,windows:large.surface.window_count,close_controls:2,ms:Math.round(duration),passed:true});
 await dispose();
 await start('slow');let started=performance.now();const inflight=observe().then(x=>({snapshot:x}),error=>({error:String(error)}));
 await sleep(750);let time=performance.now();const permissions=await control.request('tools/call',{name:'use_permissions',arguments:{}});
 const permissionMs=performance.now()-time;assert.notEqual(permissions.isError,true);assert.ok(permissionMs<2000);
 time=performance.now();await control.request('pause');const stopMs=performance.now()-time;assert.ok(stopMs<3000);
 const cancelled=await inflight;assert.ok(cancelled.error);await control.request('resume');
 results.push({mode:'slow-stop',permission_ms:Math.round(permissionMs),stop_ms:Math.round(stopMs),passed:true});
 await dispose();
 // A new observation after cancellation proves the serial collector actually
 // stopped, not just that its caller received an early cancellation response.
 await start('close-stay');started=performance.now();const afterStop=await observe('OCU observation close-stay');
 const resumedMs=performance.now()-started;assert.ok(afterStop.surface.windows.length===1&&resumedMs<5000);
 results.push({mode:'after-stop-new-observation',ms:Math.round(resumedMs),passed:true});await dispose();
 console.log(JSON.stringify({evidence:base,results}));
}finally{
 await dispose();await writeFile(join(base,'live-results.json'),JSON.stringify(results,null,2));
 await control.request('resume').catch(()=>{});client.close();control.close();
}
