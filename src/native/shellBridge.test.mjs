import assert from 'node:assert/strict';
import test from 'node:test';
import { groupNativeLayers, layerNativeStatus } from './shellBridge.js';

test('a keyed layer reports Needs server and a failed one reports Unavailable', () => {
  assert.deepEqual(
    layerNativeStatus({
      enabled: true,
      stats: { keyRequired: true },
    }),
    { status: 'needs-server', detail: 'Needs server' },
  );
  assert.equal(
    layerNativeStatus({
      enabled: false,
      stats: { error: 'Needs server, set UPLINK', code: 'NEEDS_SERVER' },
    }).detail,
    'Needs server',
  );
  assert.equal(
    layerNativeStatus({
      enabled: true,
      stats: { error: 'CelesTrak unreachable', unavailable: true },
    }).status,
    'unavailable',
  );
  assert.equal(
    layerNativeStatus({ enabled: true, stats: { count: 4 } }).status,
    'ok',
  );
});

test('layers keep panel groups and only an enabled row carries chips', () => {
  const groups = groupNativeLayers(
    [
      { id: 'flights', name: 'Live Flights', enabled: true, stats: {} },
      {
        id: 'satellites',
        name: 'Satellites',
        enabled: true,
        stats: { count: 2 },
      },
      { id: 'custom-extra', name: 'Extra', enabled: false, stats: {} },
    ],
    {
      satellites: {
        chips: [
          {
            id: 'class-stations',
            label: 'Stations',
            active: true,
            params: { classes: { stations: false } },
          },
        ],
      },
      flights: {
        chips: [{ id: 'skip', label: 'Skip' }],
      },
    },
  );
  assert.equal(groups[0].name, 'Movement');
  assert.deepEqual(
    groups[0].layers.map((layer) => layer.id),
    ['satellites', 'flights'],
  );
  assert.equal(groups[0].layers[0].status, 'ok');
  assert.equal(groups[0].layers[0].subgroups[0].label, 'Stations');
  assert.deepEqual(groups[0].layers[0].subgroups[0].params, {
    classes: { stations: false },
  });
  assert.deepEqual(groups[0].layers[1].subgroups, []);
  assert.equal(groups.at(-1).name, 'More');
  assert.equal(groups.at(-1).layers[0].id, 'custom-extra');
});
