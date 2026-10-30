import assert from 'node:assert/strict';

// AppKit logical activation belongs to the workflow lease. Window Server's
// foreground app must remain independent of it, including after cleanup.
export function assertFixtureFocus(state, { active, pid }) {
  assert.equal(state.appActive, active, 'Logical activation must match the workflow phase');
  assert.equal(state.frontmostUnchanged, true, 'The foreground app changed');
  assert.equal(state.frontmostAfter, state.frontmostBefore);
  assert.notEqual(state.frontmostAfter, pid, 'The fixture became the foreground app');
}

export async function waitForFixtureState(path, predicate) {
  const { readFile } = await import('node:fs/promises');
  let last;
  for (const deadline = Date.now() + 5000; Date.now() < deadline;) {
    try { last = JSON.parse(await readFile(path, 'utf8')); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (last && predicate(last)) return last;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  throw Error(`Fixture state did not reach the expected phase: ${JSON.stringify(last)}`);
}
