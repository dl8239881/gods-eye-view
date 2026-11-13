import assert from 'node:assert/strict';
import test from 'node:test';
import {
  activeApiBase,
  clearApiBase,
  installApiBase,
  normalizeApiBase,
  rewriteApiUrl,
  saveApiBase,
  storedApiBase,
} from './apiBase.js';

function memoryStorage() {
  const values = new Map();
  return {
    getItem: (key) => (values.has(key) ? values.get(key) : null),
    setItem: (key, value) => values.set(key, String(value)),
    removeItem: (key) => values.delete(key),
  };
}

test('an API base is an http(s) origin without credentials', () => {
  assert.equal(normalizeApiBase(''), '');
  assert.equal(normalizeApiBase('   '), '');
  assert.equal(normalizeApiBase('not a url'), '');
  assert.equal(normalizeApiBase('javascript:alert(1)'), '');
  assert.equal(normalizeApiBase('https://user:pass@globe.example/'), '');
  assert.equal(normalizeApiBase('https://globe.example/path?x=1'), '');
  assert.equal(
    normalizeApiBase('https://globe.example/gev/'),
    'https://globe.example/gev',
  );
  assert.equal(
    normalizeApiBase('https://globe.example/api'),
    'https://globe.example',
  );
  assert.equal(
    normalizeApiBase('https://globe.example/gev/api/'),
    'https://globe.example/gev',
  );
});

test('relative and same-document /api URLs follow the base; other URLs do not', () => {
  const base = 'https://globe.example';
  const page = 'capacitor://localhost/index.html';
  assert.equal(rewriteApiUrl('/api/flights', '', page), '/api/flights');
  assert.equal(
    rewriteApiUrl('/api/flights?x=1', base, page),
    'https://globe.example/api/flights?x=1',
  );
  assert.equal(
    rewriteApiUrl('capacitor://localhost/api/vessels', base, page),
    'https://globe.example/api/vessels',
  );
  assert.equal(
    rewriteApiUrl('https://tiles.example/api/v1/tile', base, page),
    'https://tiles.example/api/v1/tile',
  );
  assert.equal(
    rewriteApiUrl('https://globe.example/api/flights', base, page),
    'https://globe.example/api/flights',
  );
  assert.equal(rewriteApiUrl('/logo.svg', base, page), '/logo.svg');
  assert.equal(
    rewriteApiUrl(
      'http://localhost:4173/api/terrain/heights',
      base,
      'http://localhost:4173/',
    ),
    'https://globe.example/api/terrain/heights',
  );
});

test('a saved uplink overrides the build, and clearing it forgets the override', () => {
  const store = memoryStorage();
  assert.equal(storedApiBase(store), undefined);
  assert.equal(
    saveApiBase('https://globe.example/api/', store),
    'https://globe.example',
  );
  assert.equal(activeApiBase(store), 'https://globe.example');
  assert.equal(saveApiBase('ftp://globe.example', store), null);
  assert.equal(activeApiBase(store), 'https://globe.example');
  assert.equal(saveApiBase('', store), '');
  assert.equal(activeApiBase(store), '');
  clearApiBase(store);
  assert.equal(storedApiBase(store), undefined);
});

test('installing the wrapper rewrites fetch, XHR and sendBeacon only when a base is set', async () => {
  const store = memoryStorage();
  const calls = [];
  const scope = {
    location: { href: 'capacitor://localhost/' },
    fetch(input) {
      calls.push(['fetch', String(input)]);
      return Promise.resolve({ ok: true });
    },
    XMLHttpRequest: class {
      open(method, url) {
        calls.push(['xhr', String(url), method]);
      }
    },
    navigator: {
      sendBeacon(url) {
        calls.push(['beacon', String(url)]);
        return true;
      },
    },
  };
  try {
    installApiBase(scope, store);
    installApiBase(scope, store);
    await scope.fetch('/api/flights');
    scope.XMLHttpRequest.prototype; // constructed via open on instances
    const xhr = new scope.XMLHttpRequest();
    xhr.open('GET', '/api/terrain/heights');
    scope.navigator.sendBeacon('/logo.svg');
    assert.deepEqual(calls, [
      ['fetch', '/api/flights'],
      ['xhr', '/api/terrain/heights', 'GET'],
      ['beacon', '/logo.svg'],
    ]);
    calls.length = 0;
    saveApiBase('https://globe.example', store);
    await scope.fetch('/api/flights');
    new scope.XMLHttpRequest().open('GET', 'https://tiles.example/api/v1');
    scope.navigator.sendBeacon('/api/realtime/debug-log');
    assert.deepEqual(calls, [
      ['fetch', 'https://globe.example/api/flights'],
      ['xhr', 'https://tiles.example/api/v1', 'GET'],
      ['beacon', 'https://globe.example/api/realtime/debug-log'],
    ]);
  } finally {
    clearApiBase(store);
  }
});
