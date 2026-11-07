import assert from 'node:assert/strict';

// Fully offscreen subtrees expose their distinct text on the summary root.
// Its id is the native scroll_to_visible target, even when the link is folded.
export function offscreenTarget(nodes, name, role) {
  const target = nodes.find(n => n.offscreen === true &&
    ((n.role === role && n.name === name) || n.text?.split(' · ').includes(name)));
  assert.ok(target, `Missing offscreen target: ${name}`);
  return target;
}
