/**
 * Where the page sends `/api` calls.
 *
 * The web app and the dev server share an origin, so the base is empty and
 * every relative `/api` URL is left alone. A Capacitor build has no Node
 * server inside the WebView: `VITE_API_BASE` (build time) or the UPLINK
 * setting (localStorage, which wins) prefixes those calls with a hosted
 * server. Keys stay on that server.
 */

const STORAGE_KEY = 'gev.apiBase';

/**
 * An http(s) origin, plus an optional path prefix, or `''` when unset or
 * invalid. A trailing `/api` is stripped so the prefix is the server root.
 * @param {unknown} value
 * @returns {string}
 */
export function normalizeApiBase(value) {
  const text = String(value ?? '').trim();
  if (!text) return '';
  let url;
  try {
    url = new URL(text);
  } catch {
    return '';
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return '';
  if (url.username || url.password || url.search || url.hash) return '';
  if (!url.hostname) return '';
  let path = url.pathname.replace(/\/+$/, '');
  if (path === '/api') path = '';
  else if (path.endsWith('/api'))
    path = path.slice(0, -'/api'.length).replace(/\/+$/, '');
  return `${url.origin}${path}`;
}

function storage(override) {
  if (override) return override;
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

/**
 * The saved override. `undefined` means the user has not chosen; `''` means
 * they chose this page's own server, which hides a build-time base.
 * @param {Storage} [store]
 * @returns {string|undefined}
 */
export function storedApiBase(store = storage()) {
  if (!store) return undefined;
  let raw;
  try {
    raw = store.getItem(STORAGE_KEY);
  } catch {
    return undefined;
  }
  if (raw == null) return undefined;
  return normalizeApiBase(raw);
}

/** The base baked in by Vite. Empty when `VITE_API_BASE` is unset. */
export function buildTimeApiBase() {
  return normalizeApiBase(import.meta.env?.VITE_API_BASE);
}

/**
 * The base in effect for the next request.
 * @param {Storage} [store]
 */
export function activeApiBase(store = storage()) {
  const stored = storedApiBase(store);
  if (stored !== undefined) return stored;
  return buildTimeApiBase();
}

/**
 * Remember a base. A blank value selects this page's own server.
 * @param {unknown} value
 * @param {Storage} [store]
 * @returns {string|null} The stored base, `''` for same-origin, or null when invalid.
 */
export function saveApiBase(value, store = storage()) {
  if (!store) return null;
  const text = String(value ?? '').trim();
  if (!text) {
    store.setItem(STORAGE_KEY, '');
    return '';
  }
  const normalized = normalizeApiBase(text);
  if (!normalized) return null;
  store.setItem(STORAGE_KEY, normalized);
  return normalized;
}

/**
 * Forget the override so the build-time base (or same-origin) applies.
 * @param {Storage} [store]
 */
export function clearApiBase(store = storage()) {
  try {
    store?.removeItem(STORAGE_KEY);
  } catch {
    /* Storage is optional. */
  }
}

/** True when this page is the Capacitor or Ionic shell. */
export function isNativeShell(scope = globalThis) {
  try {
    const native = scope.Capacitor;
    if (
      typeof native?.isNativePlatform === 'function' &&
      native.isNativePlatform()
    )
      return true;
    const protocol = String(scope.location?.protocol || '');
    return protocol === 'capacitor:' || protocol === 'ionic:';
  } catch {
    return false;
  }
}

function isRootApi(raw) {
  return (
    raw === '/api' ||
    raw.startsWith('/api/') ||
    raw.startsWith('/api?') ||
    raw.startsWith('/api#')
  );
}

function isApiPathname(pathname) {
  return pathname === '/api' || pathname.startsWith('/api/');
}

function isNativeShellUrl(url) {
  const protocol = url.protocol.toLowerCase();
  return (
    (protocol === 'capacitor:' || protocol === 'ionic:') &&
    url.hostname.toLowerCase() === 'localhost'
  );
}

function sameDocument(url, pageHref) {
  if (!pageHref) return false;
  let page;
  try {
    page = new URL(pageHref);
  } catch {
    return false;
  }
  if (page.origin !== 'null' && url.origin === page.origin) return true;
  return page.protocol === url.protocol && page.host === url.host;
}

/**
 * Prefix a same-origin `/api` URL with `base`. Other URLs, including third-party
 * `/api` paths, are returned unchanged. An empty base is the identity.
 * @param {string} input
 * @param {string} base
 * @param {string} [pageHref] The page URL, so absolute same-document calls move too.
 * @returns {string}
 */
export function rewriteApiUrl(input, base, pageHref = '') {
  const target = normalizeApiBase(base);
  const raw = String(input ?? '');
  if (!target || !raw || /^(?:data|blob|filesystem):/i.test(raw)) return raw;
  if (raw === target || raw.startsWith(`${target}/`)) return raw;
  if (isRootApi(raw)) return `${target}${raw}`;
  let url;
  try {
    url = new URL(raw);
  } catch {
    return raw;
  }
  if (!isApiPathname(url.pathname)) return raw;
  if (!isNativeShellUrl(url) && !sameDocument(url, pageHref)) return raw;
  return `${target}${url.pathname}${url.search}${url.hash}`;
}

function rewriteFetchInput(input, base, pageHref) {
  if (typeof input === 'string' || input instanceof URL) {
    const next = rewriteApiUrl(String(input), base, pageHref);
    return next === String(input) ? input : next;
  }
  if (typeof Request !== 'undefined' && input instanceof Request) {
    const next = rewriteApiUrl(input.url, base, pageHref);
    if (next === input.url) return input;
    return new Request(next, input);
  }
  return input;
}

/**
 * Point `fetch`, XHR and `sendBeacon` at the active base. No-op when the base
 * is empty, and safe to call once per realm. Installed before the app modules
 * evaluate so a binding captured at import time already sees the wrapper.
 * @param {typeof globalThis} [scope]
 * @param {Storage} [store] Storage the wrappers read. The page uses localStorage.
 */
export function installApiBase(scope = globalThis, store = storage()) {
  if (!scope || scope.__gevApiBaseInstalled) return;
  Object.defineProperty(scope, '__gevApiBaseInstalled', { value: true });
  const pageHref = () => {
    try {
      return scope.location?.href || '';
    } catch {
      return '';
    }
  };
  const baseNow = () => activeApiBase(store);
  if (typeof scope.fetch === 'function') {
    const nativeFetch = scope.fetch.bind(scope);
    scope.fetch = (input, init) =>
      nativeFetch(rewriteFetchInput(input, baseNow(), pageHref()), init);
  }
  const XHR = scope.XMLHttpRequest;
  if (typeof XHR?.prototype?.open === 'function') {
    const open = XHR.prototype.open;
    XHR.prototype.open = function openWithApiBase(method, url, ...rest) {
      const next =
        typeof url === 'string' || url instanceof URL
          ? rewriteApiUrl(String(url), baseNow(), pageHref())
          : url;
      return open.call(this, method, next, ...rest);
    };
  }
  const nav = scope.navigator;
  if (nav && typeof nav.sendBeacon === 'function') {
    const beacon = nav.sendBeacon.bind(nav);
    nav.sendBeacon = (url, data) =>
      beacon(rewriteApiUrl(String(url), baseNow(), pageHref()), data);
  }
}
