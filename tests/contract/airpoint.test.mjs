import assert from "node:assert/strict";
import test from "node:test";
import YAML from "yaml";
import { batchDisposition } from "../../packages/engine/computer-use-action-result.mjs";
const batchStops = result => batchDisposition(result, { targetExited: false, isLast: false }).stop;
import {
  globalPoint,
  normalizeAirpointSnapshot,
  resolveAirpointPoint,
  resolveAirpointElement,
  nativeActionAudit,
  confirmNativeState,
  confirmWebPress,
  confirmSelection,
  confirmedTextSubmitTarget,
  observedStateChanges,
  toCanonicalYaml,
  deltaModel,
} from "../../packages/engine/computer-use-airpoint.mjs";

test('accepted web AXPress without any observed page change is unconfirmed, not completed',()=>{
  const tree=(extra=[])=>({id:'win',role:'AXWindow',children:[{id:'web',role:'AXWebArea',children:[{id:'btn',role:'AXButton',name:'Settings',frame:{x:10,y:10,w:20,h:20}},...extra]}]});
  const raw=t=>({app:{name:'Notion',pid:42},capturedAt:1,nodeCount:3,surface:{frame:{x:0,y:0,w:100,h:100},windows:[{windowID:7,frame:{x:0,y:0,w:100,h:100},tree:t}]}});
  const before=normalizeAirpointSnapshot(raw(tree()));
  const native={status:'completed',behavior:'press',element_id:'btn',operations:[{receiver_id:'btn',kind:'action',name:'AXPress',outcome:'accepted'}]};
  // Same content under new native handle ids is still no observed change.
  const renamed=normalizeAirpointSnapshot(JSON.parse(JSON.stringify(raw(tree())).replaceAll('"btn"','"btn2"')));
  const silent={...nativeActionAudit(before,native)};confirmWebPress(silent,renamed);
  assert.equal(silent.status,'unconfirmed');assert.equal(silent.code,'press_effect_unobserved');
  assert.ok(batchStops(silent));
  const opened=normalizeAirpointSnapshot(raw(tree([{id:'menu',role:'AXMenu',frame:{x:10,y:30,w:40,h:40}}])));
  const delivered={...nativeActionAudit(before,native)};confirmWebPress(delivered,opened);assert.equal(delivered.status,'completed');
  const otherProcess={...nativeActionAudit(before,native)};confirmWebPress(otherProcess,{...renamed,pid:43});assert.equal(otherProcess.status,'completed');
  assert.ok(!JSON.stringify(silent).includes('"before":{"window_id"'));
  // Native AppKit presses outside web content keep their existing semantics.
  const appkit=normalizeAirpointSnapshot(raw({id:'win',role:'AXWindow',children:[{id:'btn',role:'AXButton',name:'=',frame:{x:10,y:10,w:20,h:20}}]}));
  const plain={...nativeActionAudit(appkit,native)};confirmWebPress(plain,appkit);assert.equal(plain.status,'completed');
});

test('opened web panels built from plain groups are reported as named element changes',()=>{
  const raw=extra=>({app:{name:'Notion',pid:42},capturedAt:1,nodeCount:3,surface:{frame:{x:0,y:0,w:100,h:100},windows:[{windowID:7,frame:{x:0,y:0,w:100,h:100},
    tree:{id:'win',role:'AXWindow',children:[...extra,{id:'web',role:'AXWebArea',children:[{id:'btn',role:'AXButton',name:'Settings'}]}]}}]}});
  const before=normalizeAirpointSnapshot(raw([]));
  const after=normalizeAirpointSnapshot(raw([{id:'panel',role:'AXGroup',children:[{id:'t',role:'AXStaticText',name:'View settings'},{id:'f',role:'AXMenuItem',name:'Filter'},{id:'g',role:'AXGroup'}]}]));
  const change=observedStateChanges(before,after).items.find(c=>c.property==='named_elements');
  assert.deepEqual(change,{window_id:7,property:'named_elements',added:2,removed:0,added_examples:[{role:'AXStaticText',name:'View settings'},{role:'AXMenuItem',name:'Filter'}]});
  assert.equal(observedStateChanges(after,before).items.find(c=>c.property==='named_elements').removed,2);
  assert.equal(observedStateChanges(before,before).count,0);
});

test('window-bound pointer clicks are confirmed against the fresh window, including native windows',()=>{
  const raw=extra=>({app:{name:'App',pid:42},capturedAt:1,nodeCount:2,surface:{frame:{x:0,y:0,w:100,h:100},windows:[{windowID:3,frame:{x:0,y:0,w:100,h:100},tree:{id:'win',role:'AXWindow',children:[{id:'canvas',role:'AXGroup',frame:{x:0,y:0,w:50,h:50}},...extra]}}]}});
  const before=normalizeAirpointSnapshot(raw([]));
  const native={status:'sent',behavior:'pointer_click',element_id:'canvas',operations:[{receiver_id:'canvas',kind:'pointer',name:'LeftClick',outcome:'dispatched'}],input_trace_ids:['t']};
  const silent={...nativeActionAudit(before,native)};confirmWebPress(silent,before);
  assert.equal(silent.status,'unconfirmed');assert.equal(silent.code,'pointer_effect_unobserved');assert.ok(batchStops(silent));
  const changed=normalizeAirpointSnapshot(raw([{id:'menu',role:'AXMenu',name:'Item',frame:{x:0,y:50,w:40,h:40}}]));
  const seen={...nativeActionAudit(before,native)};confirmWebPress(seen,changed);assert.equal(seen.status,'sent');assert.ok(!batchStops(seen));
  // A click that opens its own window (Chrome's profile bubble) changed the app,
  // although the clicked window itself did not change.
  const bubble=normalizeAirpointSnapshot({...raw([]),surface:{...raw([]).surface,windows:[...raw([]).surface.windows,
    {windowID:9,frame:{x:60,y:10,w:30,h:60},tree:{id:'bubble',role:'AXWindow',frame:{x:60,y:10,w:30,h:60},children:[{id:'item',role:'AXButton',name:'Other profile',frame:{x:60,y:20,w:30,h:10}}]}}]}});
  const opened={...nativeActionAudit(before,native)};confirmWebPress(opened,bubble);assert.equal(opened.status,'sent');assert.ok(!batchStops(opened));
  const closed={...nativeActionAudit(bubble,native)};confirmWebPress(closed,before);assert.equal(closed.status,'sent');
});

test('pointer drags, long presses and surface keystrokes are dispatch receipts confirmed against the fresh window',()=>{
  const raw=extra=>({app:{name:'App',pid:42},capturedAt:1,nodeCount:2,surface:{frame:{x:0,y:0,w:100,h:100},windows:[{windowID:3,frame:{x:0,y:0,w:100,h:100},tree:{id:'win',role:'AXWindow',children:[{id:'screen',role:'AXGroup',frame:{x:0,y:0,w:50,h:50}},...extra]}}]}});
  const before=normalizeAirpointSnapshot(raw([]));
  for(const [behavior,kind,name,code] of [['pointer_drag','pointer','LeftDrag','pointer_effect_unobserved'],['pointer_long_press','pointer','LeftLongPress','pointer_effect_unobserved'],['keyboard_text','keyboard','KeyboardText','keyboard_effect_unobserved']]){
    const native={status:'sent',behavior,element_id:'screen',operations:[{receiver_id:'screen',kind,name,outcome:'dispatched'}],input_trace_ids:['t']};
    const silent={...nativeActionAudit(before,native)};confirmWebPress(silent,before);
    assert.equal(silent.status,'unconfirmed',behavior);assert.equal(silent.code,code);assert.equal(silent.effect,`${behavior}_no_observed_change`);assert.ok(batchStops(silent));
    const changed=normalizeAirpointSnapshot(raw([{id:'menu',role:'AXMenu',name:'Item',frame:{x:0,y:50,w:40,h:40}}]));
    const seen={...nativeActionAudit(before,native)};confirmWebPress(seen,changed);assert.equal(seen.status,'sent');assert.ok(!batchStops(seen));
  }
});

test('agent encoding keeps every text while collapsing fully offscreen subtrees', () => {
  const cell = (id, extra) => ({ id, role: 'AXCell', frame: { x: 0, y: 500, w: 100, h: 20 }, offscreen: true, ...extra });
  const raw = { app: { name: 'Finder', pid: 7 }, capturedAt: 1, nodeCount: 9, surface: { frame: { x: 0, y: 0, w: 400, h: 300 }, windows: [{ windowID: 1, frame: { x: 0, y: 0, w: 400, h: 300 },
    tree: { id: 'ax_1', role: 'AXWindow', frame: { x: 0, y: 0, w: 400, h: 300 }, children: [
      { id: 'ax_2', role: 'AXGroup', frame: { x: 0, y: 0, w: 400, h: 300 }, children: [
        { id: 'ax_3', role: 'AXRow', frame: { x: 0, y: 500, w: 100, h: 20 }, offscreen: true, selected: false, children: [
          cell('ax_4', { children: [{ id: 'ax_5', role: 'AXTextField', value: 'report.pdf', url: 'file:///r', selected: false, selection_range: { location: 0, length: 0 }, frame: { x: 0, y: 500, w: 100, h: 20 }, offscreen: true }] }),
          cell('ax_6', { focused: true, children: [{ id: 'ax_7', role: 'AXStaticText', name: 'PDF document', frame: { x: 0, y: 500, w: 100, h: 20 }, offscreen: true }] }) ] },
        { id: 'ax_8', role: 'AXRow', frame: { x: 0, y: 20, w: 100, h: 20 }, selected: true, children: [
          { id: 'ax_9', role: 'AXTextField', value: 'visible.txt', selection_range: { location: 0, length: 0 }, frame: { x: 0, y: 20, w: 100, h: 20 } },
          { id: 'ax_10', role: 'AXGroup' } ] } ] } ] } }] } };
  const snapshot = normalizeAirpointSnapshot(raw);
  const tree = snapshot.model.surface.windows[0].tree;
  const group = tree.children[0];
  assert.equal(group.frame, undefined, 'a frame equal to the parent is inherited');
  assert.deepEqual(group.children[0], { id: 'ax_3', role: 'AXRow', offscreen: true, text: 'report.pdf · file:///r · PDF document', focused: true });
  const visible = group.children[1];
  assert.equal(visible.selected, true);
  assert.deepEqual(visible.children[0], { id: 'ax_9', role: 'AXTextField', value: 'visible.txt' });
  assert.equal(visible.children.length, 1, 'an empty unnamed group is not shown');
  // Internal trees keep every field and every descendant for targeting and diffs.
  assert.ok(snapshot.elementReferences.get(`${snapshot.generation}/ax_5`));
  assert.ok(snapshot.elementReferences.get(`${snapshot.generation}/ax_10`));
  assert.equal(resolveAirpointElement(snapshot, 'ax_3').code, 'target_offscreen');
  assert.equal(resolveAirpointElement(snapshot, 'ax_3', { allowOffscreen: true }).elementID, 'ax_3');
  // Scrolling an offscreen row into view is a frame/offscreen change, not new UI.
  const scrolledRaw = JSON.parse(JSON.stringify(raw).replaceAll('"offscreen":true', '"offscreen":false').replaceAll('"y":500', '"y":40'));
  const changes = observedStateChanges(snapshot, normalizeAirpointSnapshot(scrolledRaw));
  assert.equal(changes.items.some(c => c.property === 'named_elements'), false);
  // Moved elements are counted per window; the snapshot carries their frames.
  assert.deepEqual(changes.items.filter(c => c.property === 'frame'), [{ window_id: 1, property: 'frame', elements: changes.count - changes.items.filter(c => c.property !== 'frame').length }]);
  assert.ok(changes.count > changes.items.length);
  // A subtree with any onscreen descendant is never collapsed.
  const partial = JSON.parse(JSON.stringify(raw)); delete partial.surface.windows[0].tree.children[0].children[0].children[1].offscreen;
  assert.ok(normalizeAirpointSnapshot(partial).model.surface.windows[0].tree.children[0].children[0].children);
});

test('agent encoding hides bare layout groups and repeated text, never content', () => {
  const f = (x, y, w, h) => ({ x, y, w, h });
  const raw = { app: { name: 'Safari', pid: 3 }, capturedAt: 1, nodeCount: 14, surface: { frame: f(0, 0, 900, 700), windows: [{ windowID: 1, frame: f(0, 0, 900, 700),
    tree: { id: 'w', role: 'AXWindow', frame: f(0, 0, 900, 700), children: [
      { id: 'e1', role: 'AXGroup', subrole: 'AXEmptyGroup', frame: f(0, 90, 900, 10) },
      { id: 'e2', role: 'AXGroup', subrole: 'AXEmptyGroup', frame: f(0, 90, 900, 10) },
      { id: 'wrap1', role: 'AXGroup', frame: f(10, 100, 200, 40), children: [
        { id: 'wrap2', role: 'AXGroup', frame: f(10, 100, 200, 40), children: [
          { id: 'link', role: 'AXLink', name: 'Billing', url: 'https://x/billing', frame: f(10, 100, 200, 40), children: [
            { id: 'linktext', role: 'AXStaticText', name: 'Billing', frame: f(12, 110, 60, 18) }] }] }] },
      { id: 'h', role: 'AXHeading', name: 'Project', frame: f(10, 150, 300, 30), children: [
        { id: 'htext', role: 'AXStaticText', name: 'Project', frame: f(10, 150, 300, 30) },
        { id: 'hother', role: 'AXStaticText', name: 'beta', frame: f(200, 150, 40, 30) }] },
      { id: 'row', role: 'AXGroup', frame: f(10, 200, 400, 30), children: [
        { id: 'label', role: 'AXStaticText', name: 'Name', frame: f(10, 200, 60, 30) },
        { id: 'field', role: 'AXTextField', value: 'Acme', frame: f(80, 200, 200, 30) }] },
      { id: 'main', role: 'AXGroup', subrole: 'AXLandmarkMain', frame: f(0, 300, 900, 400) },
      { id: 'named', role: 'AXGroup', name: 'Danger zone', frame: f(0, 300, 900, 100) },
      { id: 'ident', role: 'AXGroup', identifier: 'toolbar', frame: f(0, 300, 900, 20) },
      { id: 'web', role: 'AXWebArea', name: 'Settings', url: 'https://app.test/project/1/settings', frame: f(0, 400, 900, 300), children: [
        { id: 'same', role: 'AXLink', name: 'Billing', url: 'https://app.test/project/1/billing', frame: f(0, 400, 90, 20) },
        { id: 'ext', role: 'AXLink', name: 'Docs', url: 'https://docs.test/a', frame: f(100, 400, 90, 20) },
        { id: 'far', role: 'AXList', offscreen: true, frame: f(0, 900, 90, 20), children: [
          { id: 'farlink', role: 'AXLink', name: 'Logs', url: 'https://app.test/logs', offscreen: true, frame: f(0, 900, 90, 20) }] }] },
    ] } }] } };
  const snapshot = normalizeAirpointSnapshot(raw);
  const tree = snapshot.model.surface.windows[0].tree;
  const shown = new Map();
  (function walk(node) { shown.set(node.id, node); (node.children ?? []).forEach(walk); })(tree);
  for (const id of ['e1', 'e2', 'wrap1', 'wrap2', 'linktext', 'htext']) assert.equal(shown.has(id), false, `${id} is not shown`);
  for (const id of ['link', 'h', 'hother', 'row', 'label', 'field', 'main', 'named', 'ident']) assert.ok(shown.has(id), `${id} is shown`);
  // The wrapped link takes its wrapper's place, with its own complete frame.
  assert.deepEqual(tree.children[0], { id: 'link', role: 'AXLink', name: 'Billing', url: 'https://x/billing', frame: [10, 100, 200, 40] });
  assert.deepEqual(shown.get('h').children, [{ id: 'hother', role: 'AXStaticText', name: 'beta', frame: [200, 150, 40, 30] }]);
  assert.equal(tree.frame, undefined, 'a root frame equal to the window frame is inherited');
  // Same-origin URLs inside a web area are paths; the web area keeps its full address.
  assert.equal(shown.get('web').url, 'https://app.test/project/1/settings');
  assert.equal(shown.get('same').url, '/project/1/billing');
  assert.equal(shown.get('ext').url, 'https://docs.test/a');
  assert.equal(shown.get('far').text, 'Logs · /logs');
  // Hidden nodes still exist for targeting: a click on the link reaches its wrappers.
  for (const id of ['e1', 'wrap1', 'linktext']) assert.ok(snapshot.elementReferences.get(`${snapshot.generation}/${id}`));
  assert.equal(resolveAirpointElement(snapshot, 'wrap2').elementID, 'wrap2');
  // Encoded as compact JSON that YAML and JSON parsers both accept.
  const text = toCanonicalYaml(snapshot.model);
  assert.deepEqual(JSON.parse(text), YAML.parse(text));
  assert.ok(!text.includes(': ') && !text.includes(', '));
});

test('post-action results send only what changed since the last delivered snapshot', () => {
  const make = (panel, title = 'Doc') => normalizeAirpointSnapshot({ app: { name: 'Notion', pid: 9 }, capturedAt: 1, nodeCount: 6, surface: { frame: { x: 0, y: 0, w: 500, h: 500 }, windows: [
    { windowID: 1, title, frame: { x: 0, y: 0, w: 500, h: 500 }, tree: { id: 'ax_1', role: 'AXWindow', frame: { x: 0, y: 0, w: 500, h: 500 }, children: [
      { id: 'ax_2', role: 'AXGroup', name: 'Sidebar', frame: { x: 0, y: 0, w: 100, h: 500 }, children: [{ id: 'ax_3', role: 'AXButton', name: 'Home', frame: { x: 0, y: 0, w: 100, h: 20 } }] },
      { id: 'ax_4', role: 'AXButton', name: 'Settings', frame: { x: 400, y: 0, w: 20, h: 20 }, ...(panel ? { focused: true } : {}) },
      ...(panel ? [{ id: 'ax_5', role: 'AXGroup', name: 'View settings', frame: { x: 300, y: 30, w: 200, h: 300 }, children: [{ id: 'ax_6', role: 'AXMenuItem', name: 'Filter', frame: { x: 300, y: 40, w: 200, h: 20 } }] }] : []) ] } },
    { windowID: 2, title: 'Other', frame: { x: 0, y: 0, w: 50, h: 50 }, tree: { id: 'ax_9', role: 'AXWindow', frame: { x: 0, y: 0, w: 50, h: 50 } } } ] } }).model;
  const before = make(false), after = make(true);
  const delta = deltaModel(before, after);
  assert.equal(delta.changes_since, before.observation);
  const [main, other] = delta.surface.windows;
  assert.deepEqual(other, { window_id: 2, title: 'Other', unchanged: true });
  assert.equal(main.tree.children[0], 'ax_2', 'an identical subtree is its bare id');
  assert.equal(main.tree.children[1].focused, true);
  assert.deepEqual(main.tree.children[2], after.surface.windows[0].tree.children[2], 'new UI is complete');
  // Without a previous delivery, or for another process, the full model is sent.
  assert.equal(deltaModel(undefined, after), after);
  assert.equal(deltaModel({ ...before, application: { ...before.application, pid: 10 } }, after), after);
  assert.equal(deltaModel(after, make(true)).surface.windows.every(w => w.unchanged), true);
});

test('selection the readback could not show is confirmed from the fresh capture', () => {
  const raw = (selected, title = 'Recents') => ({ app: { name: 'Finder', pid: 4 }, capturedAt: 1, nodeCount: 3, surface: { frame: { x: 0, y: 0, w: 300, h: 300 }, windows: [{ windowID: 5, title, frame: { x: 0, y: 0, w: 300, h: 300 },
    tree: { id: 'ax_1', role: 'AXWindow', name: title, frame: { x: 0, y: 0, w: 300, h: 300 }, children: [{ id: 'ax_2', role: 'AXOutline', frame: { x: 0, y: 0, w: 100, h: 300 }, children: [{ id: 'ax_3', role: 'AXRow', name: 'Downloads', selected, frame: { x: 0, y: 40, w: 100, h: 20 } }] }] } }] } });
  const before = normalizeAirpointSnapshot(raw(false));
  const native = { status: 'completed', behavior: 'select', element_id: 'ax_3', effect: 'selection_unconfirmed', selection_check: { receiver_id: 'ax_3' },
    operations: [{ receiver_id: 'ax_2', kind: 'attribute', name: 'AXSelectedRows', outcome: 'accepted', native_error: 0 }] };
  const audit = () => ({ ...nativeActionAudit(before, native) });
  const selected = audit(); confirmSelection(selected, normalizeAirpointSnapshot(raw(true))); assert.equal(selected.effect, 'selection_set'); assert.equal(selected.status, 'completed');
  const navigated = audit(); confirmSelection(navigated, normalizeAirpointSnapshot(raw(false, 'Downloads'))); assert.equal(navigated.effect, 'selection_changed_window');
  const ignored = audit(); confirmSelection(ignored, normalizeAirpointSnapshot(raw(false))); assert.equal(ignored.status, 'unconfirmed'); assert.equal(ignored.code, 'selection_not_confirmed');
  assert.ok(batchStops(ignored)); assert.ok(!batchStops(navigated));
});

test('literal text dispatch requires fresh exact receiver confirmation before submit',()=>{
  const raw={app:{name:'App',pid:42},capturedAt:1,nodeCount:1,surface:{frame:{x:0,y:0,w:100,h:100},windows:[{windowID:1,frame:{x:0,y:0,w:100,h:100},tree:{id:'text',role:'AXTextArea',value:'old'}}]}};
  const before=normalizeAirpointSnapshot(raw);
  const native={status:'sent',behavior:'text_input',element_id:'text',operations:[{receiver_id:'text',kind:'keyboard',name:'TextInput',outcome:'dispatched'}],text_check:{receiver_id:'text',expected:'new😀\\n{return}',submit:true}};
  const receipt=()=>({...nativeActionAudit(before,native)});
  const stopped=receipt();confirmNativeState(stopped,before);
  assert.equal(stopped.status,'unconfirmed');assert.equal(confirmedTextSubmitTarget(stopped,before),undefined);
  const after=normalizeAirpointSnapshot({...raw,capturedAt:2,surface:{...raw.surface,windows:[{...raw.surface.windows[0],tree:{...raw.surface.windows[0].tree,value:native.text_check.expected}}]}});
  const good=receipt();confirmNativeState(good,after);assert.equal(good.status,'completed');assert.equal(confirmedTextSubmitTarget(good,after),after.nativeReferences.get('text'));
  assert.ok(!JSON.stringify(good).includes('new😀'));assert.ok(!JSON.stringify(good).includes('text_check'));
  const wrongProcess=receipt();confirmNativeState(wrongProcess,{...after,pid:43});assert.equal(wrongProcess.status,'unconfirmed');
});

test("accepted asynchronous scroll is checked against fresh retained state without replay", () => {
  const raw = { app:{name:"App",pid:42}, capturedAt:1,nodeCount:1,
    surface:{frame:{x:0,y:0,w:100,h:100},windows:[{windowID:1,frame:{x:0,y:0,w:100,h:100},tree:{id:"bar",role:"AXScrollBar",value:0}}]}};
  const before=normalizeAirpointSnapshot(raw);
  const native={status:"completed",behavior:"scroll",element_id:"bar",operations:[{receiver_id:"bar",kind:"attribute",name:"AXValue",outcome:"accepted"}],
    state_check:{receiver_id:"bar",property:"value",comparison:"increase",before:0,matched_effect:"scroll_position_changed"}};
  const result={...nativeActionAudit(before,native)};
  const after=normalizeAirpointSnapshot({...raw,capturedAt:2,surface:{...raw.surface,windows:[{...raw.surface.windows[0],tree:{id:"bar",role:"AXScrollBar",value:0.3}}]}});
  confirmNativeState(result,after);
  assert.equal(result.status,"completed");assert.equal(result.effect,"scroll_position_changed");
  assert.deepEqual(result.state_confirmation,{property:"value",before:0,after:0.3,matched:true});
  assert.doesNotMatch(JSON.stringify(result),/receiver_id.*comparison|matched_effect/);
  const unchanged={...nativeActionAudit(before,native)};
  confirmNativeState(unchanged,before);
  assert.equal(unchanged.status,"unconfirmed");
  assert.equal(unchanged.native_operations.length,1);
  const foreign=normalizeAirpointSnapshot({...raw,surface:{...raw.surface,windows:[{...raw.surface.windows[0],windowID:2}]}});
  const absent={...nativeActionAudit(before,native)};confirmNativeState(absent,foreign);
  assert.equal(absent.status,"unconfirmed");assert.equal(absent.state_confirmation.after,undefined);
});

test("native URLs survive normalization and compact YAML without substitution", () => {
  const snapshot = fixture();
  const raw = { app:{name:"App",pid:42}, capturedAt:1,nodeCount:1,
    surface:{frame:{x:0,y:0,w:100,h:100},windows:[{windowID:1,frame:{x:0,y:0,w:100,h:100},
      tree:{id:"link",role:"AXLink",url:"https://example.com/a%20b?x=1&y=2#part",document:"file:///Folder%20Name/Doc.rtf",offscreen:true}}]}};
  const normalized = normalizeAirpointSnapshot(raw);
  const tree = YAML.parse(toCanonicalYaml(normalized.model)).surface.windows[0].tree;
  assert.equal(tree.url,raw.surface.windows[0].tree.url);
  assert.equal(tree.document,raw.surface.windows[0].tree.document);
  assert.equal(resolveAirpointElement(normalized,tree.id).code,"target_offscreen");
  assert.equal(resolveAirpointElement(normalized,tree.id,{allowOffscreen:true}).elementID,"link");
  assert.equal(resolveAirpointElement(snapshot,tree.id,{allowOffscreen:true}).code,"element_reference_expired");
});

test("retained overflow descendants route to their owning window", () => {
  const snapshot = normalizeAirpointSnapshot({ app:{name:"App",pid:42}, capturedAt:1,nodeCount:3,
    surface:{frame:{x:0,y:0,w:200,h:200},windows:[{windowID:1,frame:{x:0,y:50,w:200,h:150},
      tree:{id:"window",role:"AXWindow",frame:{x:0,y:50,w:200,h:150},children:[
        {id:"menu",role:"AXMenu",frame:{x:20,y:0,w:100,h:60},children:[{id:"item",role:"AXMenuItem",frame:{x:20,y:5,w:100,h:20}}]}
      ]}}]}});
  assert.equal(resolveAirpointPoint(snapshot,{x:30,y:10}).windowID,1);
  assert.equal(resolveAirpointPoint(snapshot,{x:150,y:10}).noEffect,true);
});

test("state receipts retain selected range, formatting and numeric zero without repeating large text", () => {
  const before = fixture(), after = fixture();
  const tree = after.internalWindows[0].tree;
  tree.value = "x".repeat(1000); tree.selection_range = { location: 0, length: 13 }; tree.selection_style = [{ location: 0, length: 13, bold: true }];
  const changes = observedStateChanges(before, after);
  assert.equal(changes.count, 3);
  assert.deepEqual(changes.items.find(c => c.property === "value").after, { character_count: 1000, summary_only: true });
  const raw = { app: {name:"App",pid:123}, surface:{frame:{x:0,y:0,w:100,h:100},windows:[{windowID:1,frame:{x:0,y:0,w:100,h:100},tree:{id:"1",role:"AXScrollBar",value:0,selection_range:{location:1,length:2}}}]}, nodeCount:1, capturedAt:1 };
  const normalized = normalizeAirpointSnapshot(raw);
  assert.equal(normalized.model.surface.windows[0].tree.value, 0);
  assert.deepEqual(normalized.model.surface.windows[0].tree.selection_range, {location:1,length:2});
});

test("confirmed scoped closure does not report other windows closed or allow stale points", () => {
  const before = fixture();
  const after = normalizeAirpointSnapshot({ app:{name:"App",pid:123},surface:{closedWindowID:before.model.surface.windows[0].window_id,windows:[]},nodeCount:0,capturedAt:2 });
  assert.equal(observedStateChanges(before,after).count, 1);
  assert.equal(after.model.surface.available, false);
  assert.equal(resolveAirpointPoint(after,{x:0,y:0}).ok,false);
});

test("hidden cached scoped windows remain non-actionable without claiming other windows closed", () => {
  const before = fixture();
  const id = before.model.surface.windows[0].window_id;
  const after = normalizeAirpointSnapshot({app:{name:"App",pid:123},surface:{unavailableWindowID:id,windows:[]},nodeCount:0,capturedAt:2});
  assert.deepEqual(observedStateChanges(before,after).items, [{window_id:id,property:"window",before:"present",after:"not_observable"}]);
  assert.equal(after.model.surface.closed_window_id,undefined);
  assert.equal(resolveAirpointPoint(after,{x:0,y:0}).ok,false);
});

function fixture() {
  return normalizeAirpointSnapshot({
    app: { name: "Example", bundleIdentifier: "app.example", pid: 42 },
    capturedAt: 1234,
    nodeCount: 8,
    preservation: {
      frontmostApplicationUnchanged: true,
      physicalPointerUnchanged: true,
    },
    surface: {
      frame: { x: 400, y: 200, w: 800, h: 600 },
      windows: [{
        windowID: 18,
        title: "Transient Panel",
        zIndex: 0,
        frame: { x: 1000, y: 220, w: 180, h: 120 },
        tree: {
          id: "ax_panel",
          role: "AXWindow",
          name: "Transient Panel",
          frame: { x: 1000, y: 220, w: 180, h: 120 },
          actions: [],
          writableAttributes: [],
          children: [{
            id: "ax_panel_button",
            role: "AXButton",
            name: "Panel Action",
            frame: { x: 1020, y: 240, w: 120, h: 30 },
            actions: ["AXPress"],
            writableAttributes: [],
          }],
        },
      }, {
        windowID: 17,
        title: "Document",
        zIndex: 1,
        frame: { x: 400, y: 200, w: 800, h: 600 },
        tree: {
          id: "ax_1",
          role: "AXWindow",
          name: "Document",
          frame: { x: 400, y: 200, w: 800, h: 600 },
          actions: [],
          writableAttributes: [],
          children: [
        {
          id: "ax_2",
          role: "AXButton",
          name: "Save",
          frame: { x: 420, y: 220, w: 80, h: 30 },
          actions: ["AXPress"],
          writableAttributes: [],
          children: [{
            id: "ax_3",
            role: "AXStaticText",
            name: "Save",
            frame: { x: 438, y: 226, w: 42, h: 18 },
            actions: [],
            writableAttributes: [],
          }],
        },
        {
          id: "ax_4",
          role: "AXTextField",
          subrole: "AXSearchField",
          name: "Search",
          frame: { x: 600, y: 220, w: 240, h: 30 },
          actions: [],
          writableAttributes: ["AXFocused", "AXValue"],
        },
        {
          id: "ax_5",
          role: "AXSlider",
          name: "Volume",
          frame: { x: 500, y: 700, w: 200, h: 20 },
          actions: [],
          writableAttributes: ["AXValue"],
          children: [{
            id: "ax_5_thumb",
            role: "AXValueIndicator",
            frame: { x: 545, y: 700, w: 10, h: 20 },
            actions: [],
            writableAttributes: ["AXValue"],
          }],
        },
        {
          id: "ax_6",
          role: "AXOutline",
          name: "Library",
          frame: { x: 420, y: 300, w: 220, h: 80 },
          actions: [],
          writableAttributes: ["AXSelectedRows"],
          children: [{
            id: "ax_7",
            role: "AXRow",
            name: "Songs",
            frame: { x: 425, y: 305, w: 210, h: 30 },
            actions: [],
            writableAttributes: [],
          }],
        },
        {
          id: "ax_8",
          role: "AXScrollArea",
          name: "Results",
          frame: { x: 900, y: 500, w: 250, h: 120 },
          actions: [],
          writableAttributes: [],
          children: [{
            id: "ax_9",
            role: "AXStaticText",
            name: "Offscreen overlap",
            frame: { x: 600, y: 220, w: 240, h: 30 },
            offscreen: true,
            actions: [],
            writableAttributes: [],
          }],
        },
          ],
        },
      }],
    },
  });
}

test("normalizes all AX frames to the application surface", () => {
  const snapshot = fixture();
  assert.deepEqual(snapshot.model.coordinate_space, { origin: "application-surface", units: "points", width: 800, height: 600 });
  assert.deepEqual(snapshot.model.surface.windows[1].tree.children[0].frame, [20, 20, 80, 30]);
  assert.deepEqual(globalPoint(snapshot, { x: 220, y: 35 }), { x: 620, y: 235 });
});

test("coordinate routing pins the topmost observed window without predicting behavior", () => {
  const result = resolveAirpointPoint(fixture(), { x: 680, y: 55 });
  assert.deepEqual(result, { ok: true, windowID: 18, global: { x: 1080, y: 255 } });
  assert.equal(result.behavior, undefined);
});

test("invalid coordinates fail before requesting native work", () => {
  for (const point of [{ x: NaN, y: 3 }, { x: Infinity, y: 0 }, { x: -1, y: 0 }, { x: 800, y: 0 }]) {
    assert.equal(resolveAirpointPoint(fixture(), point).ok, false);
  }
});

test("a point in a gap between application windows has no effect", () => {
  const snapshot = fixture();
  snapshot.internalWindows[1].frame.width = 100;
  assert.deepEqual(resolveAirpointPoint(snapshot, { x: 500, y: 300 }), { ok: true, noEffect: true });
});

test("native audit reports selection and actual attribute receiver without claiming navigation", () => {
  const native = { status: "completed", behavior: "select", element_id: "ax_7", effect: "selection_set",
    operations: [{ receiver_id: "ax_6", kind: "attribute", name: "AXSelectedRows", outcome: "accepted", native_error: 0 }] };
  const snapshot = fixture();
  const audit = nativeActionAudit(snapshot, native, { x: 80, y: 120 });
  assert.equal(audit.behavior, "select"); assert.equal(audit.resolved_element.id, "ax_7");
  assert.equal(audit.native_operations[0].receiver_id, "ax_6");
  assert.equal(audit.native_operations[0].receiver.role, "AXOutline");
  assert.equal(audit.observation_captured_at, 1234);
  assert.equal(audit.task_outcome, undefined);
});

test("pending and unsupported native results are forwarded truthfully", () => {
  const pending = nativeActionAudit(fixture(), { status: "pending", behavior: "show_menu", element_id: "ax_2", operations: [], effect: "native_call_pending" }, { x: 60, y: 35 });
  assert.equal(pending.status, "pending");
  const supported = [{ id: "ax_2", actions: ["AXPress"], writableAttributes: [] }];
  const snapshot = fixture();
  const failed = nativeActionAudit(snapshot, { status: "failed", behavior: "none", operations: [], code: "unsupported_native_action", supported }, { x: 60, y: 35 });
  assert.deepEqual(failed.supported, supported);
  assert.equal(failed.code, "unsupported_native_action");
});

test("malformed or unobserved native references cannot be audited as success", () => {
  assert.throws(() => nativeActionAudit(fixture(), { status: "made_up", operations: [] }, {}), /malformed/);
  assert.throws(() => nativeActionAudit(fixture(), { status: "completed", behavior: "press", operations: [], element_id: "absent" }, {}), /outside the observation/);
});

test("compact YAML keeps the hierarchy without capability lists", () => {
  const payload = { status: "observed", snapshot: fixture().model };
  const yaml = toCanonicalYaml(payload);
  assert.deepEqual(YAML.parse(yaml), payload);
  assert.doesNotMatch(yaml, /writableAttributes|actions:/);
  assert.equal(fixture().internalWindows[0].tree.actions, undefined);
});

test("compact YAML preserves arbitrary application text without coercion", () => {
  const payload = { text: 'false: [null]\n# title\n"quoted"', empty: "", value: null,
    "key: [odd]": [false, true, 0, "yes", "null", "2026-10-11", "😀"] };
  assert.deepEqual(YAML.parse(toCanonicalYaml(payload)), payload);
});

test("windowless application snapshots are rejected", () => {
  assert.throws(() => normalizeAirpointSnapshot({ app: { name: "Example", pid: 42 }, capturedAt: 1234,
    nodeCount: 0, surface: { frame: { x: 0, y: 0, w: 0, h: 0 }, windows: [] } }), /invalid Accessibility snapshot/);
});


test("exact references bind covered controls and reject a different observation generation", () => {
  const current = fixture(), other = fixture();
  const reference = current.nativeReferences.get("ax_7");
  assert.equal(resolveAirpointElement(current, reference).elementID, "ax_7");
  assert.equal(resolveAirpointElement(other, reference).code, "element_reference_expired");
  // Agents receive bare native ids, resolved against the observation that returned them.
  assert.equal(current.model.surface.windows[0].tree.id.includes("/"), false);
  assert.equal(resolveAirpointElement(current, "ax_7").elementID, "ax_7");
  assert.equal(resolveAirpointElement(current, "ax_999").code, "element_reference_expired");
  const target = current.elementReferences.get(reference);
  target.node.offscreen = true;
  assert.equal(resolveAirpointElement(current, reference).code, "target_offscreen");
});


test("verified empty application observations stay non-actionable without claiming exit", () => {
  const before = fixture();
  const empty = normalizeAirpointSnapshot({app:{name:"Fixture",pid:77},surface:{unavailable:true,windows:[]},nodeCount:0,capturedAt:1235});
  assert.equal(empty.model.surface.available, false);
  assert.equal(empty.model.application.state, undefined);
  assert.equal(empty.internalWindows.length, 0);
  assert.ok(observedStateChanges(before,empty).items.every(c=>c.property!=="window"||c.after==="not_observable"));
});

test('menu cancellation requires fresh dismissal, including when the provider rebuilds menu handles', () => {
  const snapshot = (menuID, visible = true, pid = 42) => normalizeAirpointSnapshot({
    app: { name: 'Finder', pid }, capturedAt: 1, nodeCount: 3,
    surface: { frame: { x: 0, y: 0, w: 100, h: 100 }, windows: [{ windowID: 7,
      frame: { x: 0, y: 0, w: 100, h: 100 }, tree: { id: 'window', role: 'AXWindow', children: menuID ? [
        { id: menuID, role: 'AXMenu', children: [{ id: `${menuID}-open`, role: 'AXMenuItem',
          frame: { x: 10, y: 10, w: visible ? 80 : 0, h: visible ? 20 : 0 } }] },
      ] : [] } }] },
  });
  const before = snapshot('menu');
  const native = { status: 'sent', behavior: 'cancel_menu', element_id: 'menu', effect: 'menu_escape_sent',
    operations: [{ receiver_id: 'menu', kind: 'keyboard', name: 'Escape', outcome: 'dispatched' }] };
  for (const after of [before, snapshot('rebuilt-menu'), snapshot(null, true, 43), null]) {
    const result = { ...nativeActionAudit(before, native) };
    confirmNativeState(result, after);
    assert.equal(result.status, 'unconfirmed'); assert.equal(result.code, 'menu_dismissal_unconfirmed');
    assert.ok(batchStops(result));
    assert.equal(result.native_operations[0].name, 'Escape');
  }
  for (const after of [snapshot(null), snapshot('hidden-menu', false)]) {
    const result = { ...nativeActionAudit(before, native) };
    confirmNativeState(result, after);
    assert.equal(result.status, 'completed'); assert.equal(result.effect, 'menu_dismissed');
  }
});
