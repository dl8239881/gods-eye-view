import assert from 'node:assert/strict';
import test from 'node:test';
import { cablePolylines, decimateLine } from './geometry.js';

test('cable lines keep their ends and stay under the vertex budget', () => {
  const coords = Array.from({ length: 200 }, (_, index) => [index, index / 10]);
  const thin = decimateLine(coords, 32);
  assert.equal(thin.length <= 32, true);
  assert.deepEqual(thin[0], coords[0]);
  assert.deepEqual(thin[thin.length - 1], coords[coords.length - 1]);
  const lines = cablePolylines(
    [
      {
        geometry: { type: 'MultiLineString', coordinates: [coords, [[0, 0]]] },
      },
      { geometry: { type: 'Point', coordinates: [1, 2] } },
    ],
    32,
  );
  assert.equal(lines.length, 1);
  assert.equal(lines[0].length <= 32, true);
});
