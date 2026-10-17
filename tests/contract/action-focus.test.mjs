import test from 'node:test';
import assert from 'node:assert/strict';
import { withActionFocus, withActivationOnDemand, actionNeedsActivation, requiresActivation, ActivationRequired } from '../../packages/engine/computer-use-action-focus.mjs';

function fixture(overrides = {}) {
  const calls = [];
  const request = async (name, args) => {
    calls.push(name);
    if (overrides[name]) return overrides[name](args);
    return { success: true, stdout: JSON.stringify(name === 'beginActionFocus'
      ? { token: 'lease', mode: 'synthetic' } : { cleanup: 'restored' }) };
  };
  return { calls, context: { request, ownerPID: 77, snapshot: { pid: 42, model: { captured_at: 1 } } } };
}
test('focus surrounds dispatch and verification without an extra model tool', async () => {
  const { calls, context } = fixture();
  const r = await withActionFocus(context, async () => { calls.push('dispatch', 'observe'); return { status: 'sent' }; });
  assert.deepEqual(calls, ['beginActionFocus', 'dispatch', 'observe', 'endActionFocus']);
  assert.deepEqual(r.background_focus, { mode: 'synthetic', cleanup: 'restored' });
});
test('dispatch failure still releases native focus and does not repeat action', async () => {
  const { calls, context } = fixture();
  await assert.rejects(withActionFocus(context, async () => { calls.push('dispatch'); throw Error('native error'); }), /native error/);
  assert.deepEqual(calls, ['beginActionFocus', 'dispatch', 'endActionFocus']);
});
test('lost begin reply reconciles by owner before returning failure', async () => {
  const { calls, context } = fixture({ beginActionFocus: () => { throw Error('lost reply'); } });
  await assert.rejects(withActionFocus(context, () => assert.fail('must not dispatch')), /lost reply/);
  assert.deepEqual(calls, ['beginActionFocus', 'releaseActionFocus']);
});
test('cleanup failure preserves observed action state and stops the batch', async () => {
  const { context } = fixture({ endActionFocus: () => ({ success: false, error: 'cleanup failed' }) });
  await assert.rejects(withActionFocus(context, async () => ({ status: 'sent', observed_changes: { count: 1 } })), e => {
    assert.equal(e.code, 'background_focus_cleanup_failed');
    assert.equal(e.actionResult.observed_changes.count, 1);
    assert.equal(e.actionResult.background_focus.cleanup, 'unconfirmed'); return true;
  });
});
test('observation failure releases focus and keeps the original action result', async () => {
  const { context } = fixture();
  await assert.rejects(withActionFocus(context, async () => { throw Object.assign(Error('capture failed'), { snapshotError: true, actionResult: { status: 'sent' } }); }), e => {
    assert.equal(e.snapshotError, true); assert.equal(e.actionResult.background_focus.cleanup, 'restored'); return true;
  });
});
test('wait and open-app do not synthesize focus', async () => {
  const { calls, context } = fixture();
  assert.equal(await withActionFocus({ ...context, enabled: false }, async () => 'done'), 'done');
  assert.deepEqual(calls, []);
});
test('successful workflow action retains focus for a subsequent menu request', async () => {
  const { calls, context } = fixture();
  const result = await withActionFocus({ ...context, retain: true }, async () => ({ status: 'pending' }));
  assert.deepEqual(calls, ['beginActionFocus']); assert.equal(result.background_focus.cleanup, 'retained_for_workflow');
});
test('failed workflow action does not deactivate an app that may already have changed', async () => {
  const { calls, context } = fixture();
  const result = await withActionFocus({ ...context, retain: true }, async () => ({ status: 'failed' }));
  assert.deepEqual(calls, ['beginActionFocus']); assert.equal(result.background_focus.cleanup, 'retained_for_workflow');
});
test('recoverable observation error retains the owned workflow without replay', async () => {
  const { calls, context } = fixture();
  const actionResult={status:'pending',native_operations:[{name:'AXPress',outcome:'pending'}]};
  await assert.rejects(withActionFocus({...context,retain:true},async()=>{
    calls.push('dispatch');throw Object.assign(Error('capture failed'),{snapshotError:true,actionResult});
  }),e=>e.actionResult.background_focus.cleanup==='retained_for_workflow');
  assert.deepEqual(calls,['beginActionFocus','dispatch']);
});

test('activation is requested only for actions an inactive app ignores', () => {
  assert.ok(actionNeedsActivation({ kind: 'hotkey', keys: ['cmd', 'b'] }));
  assert.ok(actionNeedsActivation({ kind: 'type', text: 'x' }));
  assert.ok(actionNeedsActivation({ kind: 'type', text: 'x', input_method: 'accessibility', submit: true }));
  assert.ok(actionNeedsActivation({ kind: 'click', at: { x: 1, y: 1 }, input_method: 'pointer' }));
  assert.ok(actionNeedsActivation({ kind: 'drag', from: { x: 1, y: 1 }, to: { x: 9, y: 1 }, input_method: 'pointer' }));
  assert.ok(actionNeedsActivation({ kind: 'long_press', at: { x: 1, y: 1 } }));
  assert.ok(actionNeedsActivation({ kind: 'click', at: { x: 1, y: 1 }, click_count: 2 }));
  assert.ok(actionNeedsActivation({ kind: 'click', element: 'n1', modifiers: ['cmd'] }));
  for (const action of [{ kind: 'click', at: { x: 1, y: 1 } }, { kind: 'drag', from: { x: 1, y: 1 }, to: { x: 9, y: 1 } }, { kind: 'type', text: 'x', input_method: 'accessibility' }, { kind: 'scroll', direction: 'down' }, { kind: 'select_text', text: 'x' }, { kind: 'open' }, { kind: 'click', at: { x: 1, y: 1 }, click_count: 1, modifiers: [] }, { kind: 'perform_action', element: 'n1', name: 'AXShowMenu' }])
    assert.equal(actionNeedsActivation(action), false, action.kind);
});
test('an ordinary action runs without activation', async () => {
  const { calls, context } = fixture();
  const r = await withActivationOnDemand({ ...context, retain: true }, { needed: false }, async activated => { calls.push(`dispatch:${activated}`); return { status: 'completed' }; });
  assert.deepEqual(calls, ['dispatch:false']); assert.equal(r.background_focus, undefined);
});
test('native activation request repeats the undispatched action once with activation', async () => {
  const { calls, context } = fixture();
  const r = await withActivationOnDemand({ ...context, retain: true }, { needed: false }, async activated => {
    calls.push(`dispatch:${activated}`);
    const result = activated ? { status: 'sent' } : { status: 'failed', code: 'app_activation_required', native_operations: [] };
    if (!activated && requiresActivation(result)) throw new ActivationRequired();
    return result;
  });
  assert.deepEqual(calls, ['dispatch:false', 'beginActionFocus', 'dispatch:true']);
  assert.deepEqual(r.background_focus, { mode: 'synthetic', cleanup: 'retained_for_workflow' });
});
test('a dispatched or traced result is never treated as an activation retry', () => {
  assert.equal(requiresActivation({ code: 'app_activation_required', native_operations: [{ kind: 'action' }] }), false);
  assert.equal(requiresActivation({ code: 'app_activation_required', input_trace_ids: ['t'] }), false);
  assert.equal(requiresActivation({ code: 'app_activation_required', native_operations: [] }), true);
});
test('known keyboard actions activate before dispatch; open-app never does', async () => {
  const { calls, context } = fixture();
  await withActivationOnDemand({ ...context, retain: true }, { needed: true }, async activated => { calls.push(`dispatch:${activated}`); return {}; });
  await withActivationOnDemand({ ...context, retain: true }, { needed: false, never: true }, async activated => { calls.push(`open:${activated}`); return {}; });
  assert.deepEqual(calls, ['beginActionFocus', 'dispatch:true', 'open:false']);
});

test('only the action that created a synthetic activation is marked fresh', async () => {
  const { context } = fixture();
  const owned = { ...context, request: async (name) => ({ success: true, stdout: JSON.stringify(name === 'beginActionFocus' ? { token: 'fresh-lease-1', mode: 'synthetic' } : {}) }) };
  const seen = [];
  for (let i = 0; i < 2; i++) await withActivationOnDemand({ ...owned, retain: true }, { needed: true }, async (activated, fresh) => { seen.push(fresh); return {}; });
  assert.deepEqual(seen, [true, false]);
  const userActive = { ...context, request: async (name) => ({ success: true, stdout: JSON.stringify(name === 'beginActionFocus' ? { token: 'other', mode: 'user_active' } : {}) }) };
  await withActivationOnDemand({ ...userActive, retain: true }, { needed: true }, async (activated, fresh) => { seen.push(fresh); return {}; });
  assert.deepEqual(seen, [true, false, false]);
});
