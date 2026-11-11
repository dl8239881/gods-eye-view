import assert from 'node:assert/strict';
import test from 'node:test';
import { appPageAddress } from './toolCatalog.js';

test('an installed app keeps its shell address instead of an opaque origin', () => {
  assert.equal(
    appPageAddress('capacitor://localhost/index.html'),
    'capacitor://localhost/',
  );
  assert.equal(
    appPageAddress('ionic://localhost/index.html?x=1#y'),
    'ionic://localhost/',
  );
  assert.equal(
    appPageAddress('http://localhost:4173/'),
    'http://localhost:4173',
  );
  assert.equal(
    appPageAddress('https://globe.example/app/index.html'),
    'https://globe.example',
  );
});
