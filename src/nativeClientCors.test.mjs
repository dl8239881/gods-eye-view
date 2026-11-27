import assert from 'node:assert/strict';
import test from 'node:test';
import { applyNativeClientCors } from '../build/nativeClientCors.js';

function response() {
  const headers = new Map();
  return {
    headers,
    statusCode: 200,
    ended: false,
    setHeader(name, value) {
      headers.set(name.toLowerCase(), value);
    },
    end() {
      this.ended = true;
    },
  };
}

test('native shell preflight is answered and other origins are left alone', () => {
  const allowed = response();
  assert.equal(
    applyNativeClientCors(
      {
        method: 'OPTIONS',
        url: '/api/flights',
        headers: { origin: 'capacitor://localhost' },
      },
      allowed,
    ),
    true,
  );
  assert.equal(allowed.statusCode, 204);
  assert.equal(allowed.ended, true);
  assert.equal(
    allowed.headers.get('access-control-allow-origin'),
    'capacitor://localhost',
  );

  const ionic = response();
  assert.equal(
    applyNativeClientCors(
      {
        method: 'GET',
        url: '/api/vessels?limit=1',
        headers: { origin: 'ionic://localhost' },
      },
      ionic,
    ),
    false,
  );
  assert.equal(ionic.ended, false);
  assert.equal(
    ionic.headers.get('access-control-allow-origin'),
    'ionic://localhost',
  );

  const web = response();
  assert.equal(
    applyNativeClientCors(
      {
        method: 'GET',
        url: '/api/flights',
        headers: { origin: 'https://evil.example' },
      },
      web,
    ),
    false,
  );
  assert.equal(web.headers.size, 0);

  const asset = response();
  assert.equal(
    applyNativeClientCors(
      {
        method: 'GET',
        url: '/logo.svg',
        headers: { origin: 'capacitor://localhost' },
      },
      asset,
    ),
    false,
  );
  assert.equal(asset.headers.size, 0);
});
