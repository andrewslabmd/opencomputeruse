import assert from 'node:assert/strict';
import test from 'node:test';
import { interruptedActionReceipt, batchDisposition, applyInputDelivery } from '../../packages/engine/computer-use-action-result.mjs';
import { withActionFocus } from '../../packages/engine/computer-use-action-focus.mjs';
import { normalizeAirpointSnapshot, observedStateChanges, resolveAirpointPoint } from '../../packages/engine/computer-use-airpoint.mjs';

test('observation failure preserves both accepted and failed native operations without replay', async () => {
  for (const status of ['completed', 'sent', 'pending', 'failed']) {
    let calls = 0;
    const operations = [{ name: 'AXPress', outcome: 'accepted' }];
    const request = async name => ({ success: true, stdout: JSON.stringify(name === 'beginActionFocus' ? { token: 't' } : { cleanup: 'restored' }) });
    let receipt;
    try {
      await withActionFocus({ request, snapshot: { pid: 42, model: { captured_at: 1 } }, ownerPID: 1, retain: true }, async () => {
        calls++;
        throw Object.assign(Error('capture failed'), { code: 'post_action_observation_failed', snapshotError: true,
          actionResult: { index: 0, kind: 'click', status, native_operations: operations, ...(status === 'failed' ? { code: 'native_error' } : {}) } });
      });
    } catch (e) { receipt = interruptedActionReceipt(e, { index: 0, kind: 'click' }); }
    assert.equal(calls, 1); assert.equal(receipt.status, status);
    assert.deepEqual(receipt.native_operations, operations);
    assert.equal(receipt.observation_error.message, 'capture failed');
    assert.equal(receipt.background_focus.cleanup, 'retained_for_workflow');
    if (status === 'failed') assert.equal(receipt.code, 'native_error');
  }
});
test('cleanup and observation errors coexist without erasing dispatch state', () => {
  const observation = Object.assign(Error('capture failed'), { snapshotError: true, code: 'post_action_observation_failed' });
  const error = Object.assign(Error('restore failed'), { code: 'background_focus_cleanup_failed', operationError: observation, actionResult: { status: 'sent' } });
  const r = interruptedActionReceipt(error, { index: 0, kind: 'hotkey' });
  assert.equal(r.status, 'sent'); assert.equal(r.execution_error.code, error.code);
  assert.equal(r.observation_error.code, observation.code);
});
test('pre-dispatch error remains an actual failed action', () => {
  const r = interruptedActionReceipt(Error('focus unavailable'), { index: 0, kind: 'click' });
  assert.equal(r.status, 'failed'); assert.equal(r.error, 'focus unavailable');
});
test('process exit cannot upgrade a failed or pending action and prevents further dispatch', () => {
  for (const status of ['failed', 'pending', 'no_effect']) for (const isLast of [false, true]) {
    assert.deepEqual(batchDisposition({ status }, { targetExited: true, isLast }), { stop: true, status: 'stopped' });
  }
  assert.deepEqual(batchDisposition({ status: 'completed' }, { targetExited: true, isLast: true }), { stop: true, status: 'completed' });
  assert.deepEqual(batchDisposition({ status: 'completed' }, { targetExited: true, isLast: false }), { stop: true, status: 'stopped' });
  assert.deepEqual(batchDisposition({ status: 'sent' }, { targetExited: false, isLast: false }), { stop: false });
});
test('confirmed process exit is a non-actionable observation with measured lifecycle change', () => {
  const after = normalizeAirpointSnapshot({ app: { name: 'App', pid: 42 }, capturedAt: 2, nodeCount: 0,
    surface: { processExited: true, frame: { x: 0, y: 0, w: 0, h: 0 }, windows: [], captureWindowIDs: [] } });
  const before = { pid: 42, model: { application: { pid: 42 }, surface: { windows: [] } } };
  assert.equal(after.model.application.state, 'exited'); assert.equal(after.model.surface.available, false);
  assert.equal(after.internalWindows.length, 0);
  assert.deepEqual(observedStateChanges(before, after).items, [{ property: 'process', pid: 42, before: 'running', after: 'exited' }]);
  assert.notEqual(resolveAirpointPoint(after, { x: 1, y: 1 }).ok, true);
});

test('input receipt proves process delivery only and wrong receiver stops the batch', () => {
  const receipt = { trace_id: 't', target_pid: 42, received_pids: [42], watched_pids:[42,43], observer_available: true, foreground_pid_after: 43 };
  const accepted = { status: 'sent', input_trace_ids: ['t'] };
  applyInputDelivery(accepted, [receipt]);
  assert.equal(accepted.status, 'sent'); assert.equal(accepted.input_delivery[0].target_delivery_observed, true);
  const wrong = { status: 'sent', input_trace_ids: ['t'] };
  applyInputDelivery(wrong, [{ ...receipt, received_pids: [42,43] }]);
  assert.equal(wrong.code, 'input_isolation_violation'); assert.equal(wrong.status, 'failed');
  assert.deepEqual(batchDisposition(wrong, { targetExited: false, isLast: false }), { stop: true, status: 'stopped' });
});
test('missing or disabled input observations cannot claim delivery or hide dispatch errors', () => {
  const receipt = { trace_id: 't', target_pid: 42, received_pids: [42], observer_available: true };
  for (const receipts of [[], [{ ...receipt, trace_id: 'another' }], [{ ...receipt, observer_available: false }], [{ ...receipt, received_pids: [] }]]) {
    const result = { status: 'sent', input_trace_ids: ['t'] }; applyInputDelivery(result, receipts);
    assert.equal(result.status, 'unconfirmed');
    const failed = { status: 'failed', code: 'native_target_changed', input_trace_ids: ['t'] }; applyInputDelivery(failed, receipts);
    assert.equal(failed.status, 'failed'); assert.equal(failed.code, 'native_target_changed');
  }
});
test('foreground target and human app switching do not cancel correctly delivered input', () => {
  for (const foreground of [42,43,44]) {
    const result = { status: 'sent', input_trace_ids: ['t'] };
    applyInputDelivery(result, [{ trace_id:'t', target_pid:42, received_pids:[42], watched_pids:[42,43], observer_available:true, foreground_pid_after:foreground }]);
    assert.equal(result.status,'sent');assert.equal(result.input_scope_changed,undefined);
    assert.equal(result.input_delivery_coverage_changed,foreground===44 ? true : undefined);
    assert.deepEqual(batchDisposition(result,{targetExited:false,isLast:false}),{stop:false});
  }
});
