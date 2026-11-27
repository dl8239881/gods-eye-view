import assert from 'node:assert/strict';
import test from 'node:test';
import { nativePageScrollBlocked } from './pageScroll.js';

test('a globe touch is not allowed to scroll the page, a field is', () => {
  const canvas = { nodeType: 1, closest: () => null };
  assert.equal(nativePageScrollBlocked(canvas), true);
  assert.equal(nativePageScrollBlocked(undefined), true);
  const field = {
    nodeType: 1,
    closest: (selector) => (selector.includes('input') ? field : null),
  };
  assert.equal(nativePageScrollBlocked(field), false);
});
