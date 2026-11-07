import assert from 'node:assert/strict';
import test from 'node:test';
import { normalizeAirpointSnapshot, resolveAirpointElement } from '../../packages/engine/computer-use-airpoint.mjs';
import { offscreenTarget } from '../../scripts/live-support/offscreen-target.mjs';

const flat = n => [n, ...(n.children ?? []).flatMap(flat)];
const snapshot = offscreen => normalizeAirpointSnapshot({
  app: { name: 'Fixture', pid: 42 }, capturedAt: 1, nodeCount: 4,
  surface: { frame: { x: 0, y: 0, w: 100, h: 100 }, windows: [{
    windowID: 7, frame: { x: 0, y: 0, w: 100, h: 100 },
    tree: { id: 'window', role: 'AXWindow', children: [{
      id: 'page', role: 'AXWebArea', url: 'https://example.com/', children: [{
        id: 'link90', role: 'AXLink', name: 'Destination 90', url: 'https://example.com/item/90', offscreen,
        children: [{ id: 'label90', role: 'AXStaticText', name: 'Link description', offscreen }]
      }]
    }] }
  }] }
});

test('interaction acceptance reveals the collapsed offscreen root by its delivered id', () => {
  const before = snapshot(true), nodes = flat(before.model.surface.windows[0].tree);
  // The old acceptance lookup fails on the actual wire encoder output.
  assert.equal(nodes.find(n => n.name === 'Destination 90' && n.role === 'AXLink'), undefined);
  const target = offscreenTarget(nodes, 'Destination 90', 'AXLink');
  assert.equal(target.id, 'link90');
  assert.equal(target.offscreen, true);
  assert.equal(target.children, undefined);
  assert.ok(resolveAirpointElement(before, target.id, { allowOffscreen: true }).ok);
  const revealed = flat(snapshot(false).model.surface.windows[0].tree).find(n => n.name === 'Destination 90' && n.role === 'AXLink');
  assert.ok(revealed);
  assert.notEqual(revealed.offscreen, true);
});

test('interaction acceptance also supports expanded links and ancestor summaries', () => {
  const link = { id: 'link', role: 'AXLink', name: 'Destination 90', offscreen: true };
  assert.equal(offscreenTarget([link], 'Destination 90', 'AXLink'), link);
  const group = { id: 'group', role: 'AXGroup', text: 'Heading · Destination 90 · /item/90', offscreen: true };
  assert.equal(offscreenTarget([group], 'Destination 90', 'AXLink'), group);
  assert.throws(() => offscreenTarget([{ ...group, text: 'Destination 900' }], 'Destination 90', 'AXLink'), /Missing offscreen target/);
  assert.throws(() => offscreenTarget([{ ...link, offscreen: false }], 'Destination 90', 'AXLink'), /Missing offscreen target/);
});
