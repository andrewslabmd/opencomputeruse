import assert from 'node:assert/strict';

export const flat = n => typeof n === 'object' && n ? [n, ...(n.children ?? []).flatMap(flat)] : [];

export function finderObservationNodes(snapshot) {
  // Compact observations omit a frame equal to the parent's (and the window
  // root inherits the window frame). Resolve it before choosing an item;
  // Finder's actionable image often shares its readonly wrapper's frame.
  function expand(node, parentFrame, parentOffscreen = false) {
    assert.ok(node && typeof node === 'object', 'Finder targeting requires a full observation');
    const frame = Object.hasOwn(node, 'frame') ? node.frame : parentFrame;
    const offscreen = node.offscreen ?? parentOffscreen;
    return { ...node, frame, offscreen,
      children: (node.children ?? []).map(child => expand(child, frame, offscreen)) };
  }
  return snapshot.surface.windows.flatMap(w => flat(expand(w.tree, w.frame)));
}

export function finderItem(nodes, name) {
  const matches = nodes.filter(n => n.frame?.[2] > 0 && n.frame?.[3] > 0 && [n.name, n.value, n.identifier].includes(name) && !n.offscreen && n.enabled !== false);
  const target = matches.find(n => n.role === 'AXImage') ?? matches.find(n => n.role === 'AXStaticText') ?? matches[0];
  assert.ok(target, `Missing fixture item: ${name}`); return target;
}
