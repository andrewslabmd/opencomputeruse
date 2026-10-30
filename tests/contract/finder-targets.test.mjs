import test from 'node:test';
import assert from 'node:assert/strict';
import { finderObservationNodes, finderItem } from '../../scripts/live-support/finder-targets.mjs';

// Shape from the failed background Finder observation: the readonly wrapper
// has geometry, while its actionable AXImage inherits that same geometry.
const fixture = (child = {}, group = {}) => ({ surface: { windows: [{
  window_id: 7, frame: [0, 0, 700, 520], tree: {
    id: 'window', role: 'AXWindow', children: [{
      id: 'viewport', role: 'AXScrollArea', frame: [0, 32, 700, 460], children: [{
        id: 'collection', role: 'AXList', children: [{
          id: 'section', role: 'AXList', subrole: 'AXSectionList', enabled: false, frame: [10, 42, 448, 112], children: [{
            id: 'wrapper', role: 'AXGroup', identifier: 'Folder Alias', enabled: false,
            frame: [146, 46, 64, 64], ...group, children: [{
              id: 'image', role: 'AXImage', name: 'Folder Alias', identifier: 'Folder Alias', ...child,
            }],
          }],
        }],
      }],
    }],
  },
}] } });

test('Finder item targeting uses the AXImage with inherited geometry rather than its readonly wrapper', () => {
  const snapshot = fixture();
  const original = structuredClone(snapshot);
  const nodes = finderObservationNodes(snapshot);
  const target = finderItem(nodes, 'Folder Alias');
  assert.equal(target.id, 'image'); assert.equal(target.role, 'AXImage');
  assert.deepEqual(target.frame, [146, 46, 64, 64]);
  assert.equal(target.offscreen, false);
  assert.deepEqual(nodes.find(n => n.id === 'window').frame, [0, 0, 700, 520]);
  assert.deepEqual(nodes.find(n => n.id === 'collection').frame, [0, 32, 700, 460]);
  // AXEnabled=false on a layout ancestor does not disable the actual receiver.
  assert.notEqual(target.enabled, false);
  assert.deepEqual(snapshot, original, 'Evidence and protocol input remain unchanged');
});

test('Finder item targeting preserves explicit child geometry and names from all three text fields', () => {
  for (const nameField of ['name', 'value', 'identifier']) {
    const snapshot = fixture({ name: undefined, identifier: undefined,
      [nameField]: 'Folder Alias', frame: [150, 50, 32, 32] });
    const target = finderItem(finderObservationNodes(snapshot), 'Folder Alias');
    assert.equal(target.id, 'image'); assert.deepEqual(target.frame, [150, 50, 32, 32]);
  }
});

test('Finder targeting inherits offscreen state and refuses hidden or disabled receivers', () => {
  for (const snapshot of [fixture({}, { offscreen: true }), fixture({ offscreen: true }), fixture({ enabled: false })]) {
    assert.throws(() => finderItem(finderObservationNodes(snapshot), 'Folder Alias'), /Missing fixture item/);
  }
});

test('explicitly missing or zero child geometry is never replaced with wrapper geometry', () => {
  for (const frame of [null, [146, 46, 0, 0]]) {
    const nodes = finderObservationNodes(fixture({ frame }));
    assert.deepEqual(nodes.find(n => n.id === 'image').frame, frame);
    assert.throws(() => finderItem(nodes, 'Folder Alias'), /Missing fixture item/);
  }
});

test('Finder targeting requires a fresh full observation instead of guessing from delta references', () => {
  const snapshot = fixture();
  snapshot.surface.windows[0].tree.children = ['retained-subtree-id'];
  assert.throws(() => finderObservationNodes(snapshot), /full observation/);
});
