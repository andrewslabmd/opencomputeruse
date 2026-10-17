import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { parse } from 'yaml';
import { Client } from '../packages/cli/client.mjs';

if (!process.argv.includes('--interactive')) throw new Error('Native interaction acceptance requires --interactive authorization');
const dir = resolve(`work/native-interaction-${Date.now()}`);
await mkdir(dir, { recursive:true });
const binary=join(dir,'InteractionFixture'), statePath=join(dir,'state.json');
execFileSync('xcrun',['swiftc','tests/native-fixtures/InteractionFixture.swift','-o',binary]);
const fixture=spawn(binary,[statePath],{stdio:'ignore'});
const client=new Client();
const records=[];
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const state=async()=>JSON.parse(await readFile(statePath,'utf8'));
async function until(predicate) {
  const readyBy=Date.now()+10000; // Harness readiness only; never an agent task deadline.
  while(Date.now()<readyBy){try{const s=await state();if(predicate(s))return s;}catch{}await sleep(40);}
  throw Error('Fixture state did not become ready');
}
const flat=n=>[n,...(n.children??[]).flatMap(flat)];
const nodes=r=>r.snapshot.surface.windows.flatMap(w=>flat(w.tree));
async function call(name,args){
  const raw=await client.request('tools/call',{name,arguments:args});
  assert.notEqual(raw.isError,true,JSON.stringify(raw));
  const result=parse(raw.content.find(x=>x.type==='text').text);
  records.push({name,args,result,actual:await state()});
  await writeFile(join(dir,'results.json'),JSON.stringify(records,null,2));
  return result;
}
try{
  await until(s=>s.web?.y===0);
  await client.connect('Native scroll, reveal and save acceptance');
  const host=await client.request('status');assert.ok(!host.busy&&!host.owner&&!host.paused);
  let r=await call('use_observe',{app_target:`PID:${fixture.pid}`});
  const accessibilityReadyBy=Date.now()+10000;
  while(!nodes(r).some(n=>n.name==='Destination 1'&&n.role==='AXLink')) {
    assert.ok(Date.now()<accessibilityReadyBy,'Web accessibility did not become ready');
    await sleep(40);r=await call('use_observe',{app_target:`PID:${fixture.pid}`});
  }
  assert.equal(nodes(r).find(n=>n.name==='Destination 1'&&n.role==='AXLink').url,'https://example.com/item/1');
  for(const direction of ['down','right','up','left']){
    const before=await state();
    const owner=nodes(r).find(n=>n.role==='AXScrollArea'&&n.children?.some(x=>x.role==='AXWebArea'));
    r=await call('use_action_batch',{actions:[{kind:'scroll',element:owner.id,direction}]});
    assert.equal(r.actions[0].status,'completed',JSON.stringify(r.actions));
    const axis=['up','down'].includes(direction)?'y':'x',sign=['down','right'].includes(direction)?1:-1;
    const after=await until(s=>(s.web[axis]-before.web[axis])*sign>0);
    assert.notEqual(after.frontmost_pid,fixture.pid);
    console.log(`WebKit native scroll ${direction}: passed`);
  }
  const offscreen=nodes(r).find(n=>n.name==='Destination 90'&&n.role==='AXLink');
  assert.equal(offscreen.offscreen,true);
  r=await call('use_action_batch',{actions:[{kind:'scroll_to_visible',element:offscreen.id}]});
  assert.equal(r.actions[0].status,'completed',JSON.stringify(r.actions));
  assert.notEqual(nodes(r).find(n=>n.name==='Destination 90'&&n.role==='AXLink').offscreen,true);
  await until(s=>s.web.y>2000);
  console.log('Native reveal of exact offscreen link: passed');
  for(let i=0;i<2;i++){
    const open=nodes(r).find(n=>n.name==='Open save panel');
    r=await call('use_action_batch',{actions:[{kind:'click',element:open.id}]});
    r=await call('use_observe',{app_target:`PID:${fixture.pid}`});
    const field=nodes(r).find(n=>n.role==='AXTextField'&&n.identifier==='saveAsNameTextField');
    assert.ok(field,'Missing native filename field');
    const filename=`Native ${i===0?'value':'selected edit'} ${Date.now()}.rtf`;
    if(i===0)r=await call('use_action_batch',{actions:[{kind:'type',element:field.id,text:filename,replace:true,input_method:'accessibility'}]});
    else{
      r=await call('use_action_batch',{actions:[{kind:'select_text',element:field.id,text:field.value}]});
      r=await call('use_action_batch',{actions:[{kind:'type',element:nodes(r).find(n=>n.identifier===field.identifier).id,text:filename,input_method:'accessibility'}]});
    }
    assert.equal(r.actions[0].status,'completed',JSON.stringify(r.actions));
    const save=nodes(r).find(n=>n.role==='AXButton'&&n.name==='Save');
    assert.notEqual(save.offscreen,true,'Sheet overflow cannot hide Save');
    r=await call('use_action_batch',{actions:[{kind:'click',element:save.id}]});
    assert.equal(r.actions[0].status,'completed',JSON.stringify(r.actions));
    const actual=await until(s=>s.saves.length===i+1);
    assert.equal(actual.saves[i].url,join(dir,filename));
    assert.match(await readFile(actual.saves[i].url,'utf8'),/Native save acceptance/);
    assert.notEqual(actual.frontmost_pid,fixture.pid);
    console.log(`Native save ${i===0?'value assignment':'selected edit'}: passed`);
  }
  const open=nodes(r).find(n=>n.name==='Open save panel');
  r=await call('use_action_batch',{actions:[{kind:'click',element:open.id}]});
  r=await call('use_observe',{app_target:`PID:${fixture.pid}`});
  if(!nodes(r).some(n=>n.role==='AXButton'&&n.name==='New Folder')){
    const disclosure=nodes(r).find(n=>n.role==='AXDisclosureTriangle'&&n.identifier==='NS_OPEN_SAVE_DISCLOSURE_TRIANGLE');
    assert.ok(disclosure,'Native save panel must expose its disclosure control');
    r=await call('use_action_batch',{actions:[{kind:'click',element:disclosure.id}]});
  }
  const beforeFolder=await state();
  const newFolder=nodes(r).find(n=>n.role==='AXButton'&&n.name==='New Folder');
  assert.ok(newFolder,'Expanded native save panel must expose New Folder');
  r=await call('use_action_batch',{actions:[{kind:'click',element:newFolder.id}]});
  const folderField=nodes(r).find(n=>n.role==='AXTextField'&&n.value==='untitled folder');
  assert.ok(folderField,'Native dialog must be inspected even after an uncertain action return');
  // Activation is on demand; an uncertain action must never release the workflow's lease.
  assert.ok([undefined,'retained_for_workflow'].includes(r.actions[0].background_focus?.cleanup));
  const folder=`Created native folder ${Date.now()}`;
  const create=nodes(r).find(n=>n.role==='AXButton'&&n.name==='Create');
  r=await call('use_action_batch',{actions:[{kind:'type',element:folderField.id,text:folder,replace:true},{kind:'click',element:create.id}]});
  const field=nodes(r).find(n=>n.role==='AXTextField'&&n.identifier==='saveAsNameTextField');
  const save=nodes(r).find(n=>n.role==='AXButton'&&n.name==='Save');
  const filename=`New directory save ${Date.now()}.rtf`;
  r=await call('use_action_batch',{actions:[{kind:'type',element:field.id,text:filename,replace:true},{kind:'click',element:save.id}]});
  const saved=await until(s=>s.saves.length===3);
  assert.equal(saved.saves[2].url,join(dir,folder,filename));
  assert.equal(saved.resignations,beforeFolder.resignations,'Recoverable results must not deactivate the owned app');
  console.log('Native new-folder save retains the workflow through uncertain returns: passed');
  r=await call('use_observe',{app_target:`PID:${fixture.pid}`});
  const beforeFocus=await state();
  assert.notEqual(beforeFocus.key_window,beforeFocus.secondary_window,'Fixture must start with another key window');
  const secondaryEditor=nodes(r).find(n=>n.identifier==='secondary-editor');
  assert.ok(secondaryEditor,'Second document editor must be exposed');
  r=await call('use_action_batch',{actions:[{kind:'click',element:secondaryEditor.id},{kind:'hotkey',keys:['cmd','s']}]});
  assert.equal(r.actions[0].status,'completed',JSON.stringify(r.actions));
  assert.equal(r.actions[1].receiver.window_id,beforeFocus.secondary_window);
  const routed=await until(s=>s.shortcut_window===s.secondary_window);
  assert.equal(routed.key_window,routed.secondary_window);
  assert.notEqual(routed.frontmost_pid,fixture.pid);
  console.log('Editor click and shortcut route to the same native document window: passed');
  const literal='Unicode 😀 𝄞 é \\n {return}';
  r=await call('use_action_batch',{actions:[{kind:'type',element:nodes(r).find(n=>n.identifier==='secondary-editor').id,text:literal,replace:true,submit:true}]});
  assert.ok(['completed','sent'].includes(r.actions[0].status),JSON.stringify(r.actions));
  const submitted=await until(s=>s.submitted_text===literal);
  assert.notEqual(submitted.frontmost_pid,fixture.pid);
  console.log('Literal Unicode keyboard replacement and confirmed-input Submit: passed');
  r=await call('use_action_batch',{actions:[{kind:'type',element:nodes(r).find(n=>n.identifier==='secondary-editor').id,text:'',replace:true,submit:true}]});
  assert.ok(['completed','sent'].includes(r.actions[0].status),JSON.stringify(r.actions));
  await until(s=>s.submitted_text==='');
  console.log('Empty keyboard replacement clears only the selected editor: passed');
  await client.request('release');
  const final=await until(s=>!s.active);
  await writeFile(join(dir,'acceptance.json'),JSON.stringify({passed:true,cases:11,final,records:records.length},null,2));
  console.log(`Evidence: ${dir}`);
}finally{
  await client.request('release').catch(()=>{});client.close();fixture.kill();
}
