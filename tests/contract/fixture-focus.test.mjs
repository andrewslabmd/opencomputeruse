import test from 'node:test';
import assert from 'node:assert/strict';
import { assertFixtureFocus } from '../../scripts/live-support/fixture-focus.mjs';

const state = { appActive: true, frontmostUnchanged: true, frontmostBefore: 7, frontmostAfter: 7 };
test('native acceptance permits synthetic activation only during the lease', () => {
  assertFixtureFocus(state, { active: true, pid: 42 });
  assert.throws(() => assertFixtureFocus(state, { active: false, pid: 42 }));
  assertFixtureFocus({ ...state, appActive: false }, { active: false, pid: 42 });
  assert.throws(() => assertFixtureFocus({ ...state, appActive: false }, { active: true, pid: 42 }));
});
test('logical state never excuses the fixture taking the foreground', () => {
  for (const active of [true, false]) {
    const phase = { active, pid: 42 };
    assert.throws(() => assertFixtureFocus({ ...state, appActive: active, frontmostBefore: 42, frontmostAfter: 42 }, phase));
    assert.throws(() => assertFixtureFocus({ ...state, appActive: active, frontmostAfter: 9 }, phase));
    assert.throws(() => assertFixtureFocus({ ...state, appActive: active, frontmostUnchanged: false }, phase));
  }
});
