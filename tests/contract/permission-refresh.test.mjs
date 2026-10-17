import test from 'node:test';
import assert from 'node:assert/strict';
import { Broker } from '../../packages/host/broker.mjs';
class Probe extends Broker {
  granted = false; starts = 0; stops = 0;
  constructor() { super('unused'); }
  async readPermissions() { return [{ name: 'Accessibility', isGranted: this.granted }]; }
  async start() { this.starts++; }
  async stop() { this.stops++; }
  async request() { return { content: [] }; }
}
test('preflight never negotiates action capabilities before native grants', async () => {
  const b = new Probe(); await b.call('use_permissions', {}); assert.equal(b.starts, 0);
  await assert.rejects(b.call('use_observe', { app_target: 'Fixture' }), { code: 'permission_required' }); assert.equal(b.starts, 0);
  b.granted = true; await b.call('use_observe', { app_target: 'Fixture' }); assert.equal(b.starts, 1); assert.equal(b.stops, 1);
});
test('permission changes invalidate action state instead of silently replaying', async () => {
  const b = new Probe(); b.granted = true; await b.call('use_observe', {}); b.granted = false;
  await assert.rejects(b.call('use_action_batch', { actions: [] }), { code: 'permissions_changed' });
  assert.equal(b.stops, 1); assert.equal(b.starts, 1);
});
test('concurrent permission inspection does not reset the broker or hide a later permission change', async () => {
  const b = new Probe(); b.granted = true; await b.call('use_observe', {});
  const fingerprint = b.permissionFingerprint;
  b.granted = false; await b.call('use_permissions', {});
  assert.equal(b.stops, 0); assert.equal(b.starts, 1); assert.equal(b.permissionFingerprint, fingerprint);
  await assert.rejects(b.call('use_action_batch', {}), { code: 'permissions_changed' });
  assert.equal(b.stops, 1);
});
test('cancel during permission preflight cannot launch an action afterward', async () => {
  const b = new Probe(); const controller = new AbortController(); let complete;
  b.readPermissions = () => new Promise(resolve => { complete = resolve; });
  const call = b.call('use_observe', {}, controller.signal);
  controller.abort(); complete([{ name: 'Accessibility', isGranted: true }]);
  await assert.rejects(call, { code: 'cancelled' }); assert.equal(b.starts, 0);
});
