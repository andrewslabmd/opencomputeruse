import test from 'node:test';
import assert from 'node:assert/strict';
import Ajv from 'ajv';
import { tools } from '../../packages/protocol/tools.mjs';

test('native target schemas allow one explicit target and reject competing receivers', () => {
  const validate = new Ajv({strict:false}).compile(tools[1].inputSchema);
  for (const kind of ['click','right_click','open','perform_action','type','scroll','select_text']) {
    const extra = ['type','select_text'].includes(kind) ? {text:'hello'} : kind==='scroll' ? {direction:'down'} : {};
    assert.ok(validate({actions:[{kind,element:'generation/handle',...extra}]}));
    assert.equal(validate({actions:[{kind,element:'generation/handle',at:{x:1,y:1},...extra}]}),false);
    assert.equal(validate({actions:[{kind,...extra}]}),false);
  }
});

test('native reveal requires an exact element rather than a point', () => {
  const validate = new Ajv({strict:false}).compile(tools[1].inputSchema);
  assert.ok(validate({actions:[{kind:'scroll_to_visible',element:'generation/handle'}]}));
  assert.equal(validate({actions:[{kind:'scroll_to_visible',at:{x:1,y:1}}]}),false);
  assert.equal(validate({actions:[{kind:'scroll_to_visible',element:'generation/handle',at:{x:1,y:1}}]}),false);
});

test('repeated and modified clicks and named actions are bounded by the schema', () => {
  const validate = new Ajv({strict:false}).compile(tools[1].inputSchema);
  assert.ok(validate({actions:[{kind:'click',element:'n',click_count:2,modifiers:['cmd','shift']}]}));
  assert.ok(validate({actions:[{kind:'click',at:{x:1,y:1},click_count:3}]}));
  for (const click of [{click_count:4},{click_count:0},{modifiers:['hyper']},{modifiers:['cmd','cmd']}])
    assert.equal(validate({actions:[{kind:'click',element:'n',...click}]}),false,JSON.stringify(click));
  assert.ok(validate({actions:[{kind:'perform_action',element:'n',name:'AXShowMenu'}]}));
  assert.ok(validate({actions:[{kind:'perform_action',element:'n'}]}));
  assert.equal(validate({actions:[{kind:'perform_action',element:'n',name:''}]}),false);
  assert.equal(validate({actions:[{kind:'right_click',element:'n',click_count:2}]}),false);
  assert.ok(new Ajv({strict:false}).compile(tools.find(t => t.name === 'use_list_apps').inputSchema)({}));
});
