/**
 * Same-site request gate for the cost-bearing and log endpoints.
 *
 * The credential panel has its own stricter gate (`admitKeySetupRequest` in
 * keySetupCore.mjs): loopback socket + local Host + exact Origin + JSON
 * Content-Type. The endpoints behind this gate — `/api/realtime/token` (mints
 * an OpenAI Realtime token = spends money), `/api/openai/hud-summary` (OpenAI
 * spend), `/api/google/nearby-places` (Google spend),
 * `/api/realtime/debug-log` (appends to a local JSONL) and the quota-bearing
 * routes SECURITY.md lists with them — were previously ungated, so a hostile
 * web page open in the same browser could reach them cross-site: a `fetch`
 * carries a foreign `Origin`, and an `<img>`/navigation carries NO `Origin`
 * at all but does carry `Sec-Fetch-Site: cross-site`. The keyless map routes
 * (`/api/terrain/heights`, `/api/overpass`) reuse this core through
 * `admitSameSiteKeyless` with the forwarding-header refusal switched off.
 *
 * This module is the pure core that refuses those shapes while keeping the
 * documented `HOST=0.0.0.0` LAN opt-in and non-browser loopback tools (the two
 * repo QA harnesses POST the token endpoint from Node with no Origin) working.
 * It deliberately does NOT require a loopback remote address (that belongs only
 * to the credential panel), the presence of an `Origin`, or a JSON
 * Content-Type. It touches nothing but its arguments, so every refusal below is
 * pinned by a unit assertion.
 */
/**
 * Reverse-proxy / CDN forwarding headers. Their presence means the request did
 * not originate on this machine, whatever its socket says. This module owns
 * the list for every local gate (the credential panel and /mcp import
 * `hasProxySignals`), and has no imports so it can sit in any package boundary.
 */
export const PROXY_SIGNALS = Object.freeze([
  'forwarded',
  'via',
  'x-forwarded-for',
  'x-forwarded-host',
  'x-forwarded-port',
  'x-forwarded-proto',
  'x-real-ip',
  'cf-connecting-ip',
  'cf-ray',
]);

/**
 * Whether a request carries reverse-proxy or CDN forwarding headers. `headers`
 * is keyed by lower-case header name.
 */
export function hasProxySignals(headers = {}) {
  return PROXY_SIGNALS.some(
    (name) => String(headers[name] || '').trim() !== '',
  );
}

/**
 * Compute a request's own authority (an origin string) from its protocol and
 * Host header. Unlike the credential-panel gate's localhost-restricted
 * `localAuthority`, this returns whatever Host the request actually carries —
 * the LAN opt-in serves a non-loopback Host to LAN browsers, and a same-origin
 * fetch from such a page must still match. Malformed/missing input yields null.
 * @param {string} hostHeader e.g. `req.headers.host`
 * @param {string} protocol `http:` or `https:`
 * @returns {string|null}
 */
function requestAuthority(hostHeader, protocol) {
  const raw = String(hostHeader || '')
    .trim()
    .toLowerCase();
  const scheme = String(protocol || '').toLowerCase();
  if (!raw || !['http:', 'https:'].includes(scheme) || /[\s/?#@]/.test(raw))
    return null;
  try {
    return new URL(`${scheme}//${raw}`).origin;
  } catch {
    return null;
  }
}

/**
 * Capacitor and Ionic shell origins. A normal browser page cannot set
 * `Origin` to these schemes; WKWebView sends them for the installed app.
 * Non-special schemes have an opaque origin in the URL standard (`"null"`),
 * so this compares protocol and host rather than `URL#origin`.
 * @param {string|undefined|null} origin
 * @returns {boolean}
 */
export function isNativeAppOrigin(origin) {
  if (origin == null || origin === '' || origin === 'null') return false;
  let url;
  try {
    url = new URL(String(origin));
  } catch {
    return false;
  }
  if (url.username || url.password || url.search || url.hash) return false;
  if (url.pathname !== '' && url.pathname !== '/') return false;
  const protocol = url.protocol.toLowerCase();
  const host = url.hostname.toLowerCase();
  return (
    (protocol === 'capacitor:' || protocol === 'ionic:') && host === 'localhost'
  );
}

/**
 * Whether `GEV_TRUST_NATIVE_CLIENTS` opts a hosted server into admitting the
 * installed app through a reverse proxy. The value is read from the supplied
 * environment; the gate itself stays free of globals.
 * @param {NodeJS.ProcessEnv} [env]
 * @returns {boolean}
 */
export function trustNativeClientsFromEnv(env = {}) {
  return ['1', 'true', 'yes', 'on'].includes(
    String(env.GEV_TRUST_NATIVE_CLIENTS ?? '')
      .trim()
      .toLowerCase(),
  );
}

/**
 * Decide whether a request to a cost-bearing/log endpoint is same-site enough
 * to admit. Pure: no I/O, no globals.
 *
 * Policy, in order:
 *  1. any reverse-proxy / CDN signal header present (PROXY_SIGNALS) → 403,
 *     unless `trustNativeClients` is set and `Origin` is the Capacitor or
 *     Ionic shell (`capacitor://localhost` / `ionic://localhost`);
 *  2. `Sec-Fetch-Site` present and not `same-origin` / `none` → 403 (this is
 *     what blocks `<img src=...>` and cross-site navigation, which carry no
 *     Origin but do carry `Sec-Fetch-Site: cross-site`), unless the Origin is
 *     that native shell — WKWebView marks those fetches cross-site;
 *  3. `Origin` present must exactly equal the request's own authority computed
 *     from protocol + Host — the same exact-origin comparison the credential
 *     gate uses (no userinfo, no path/search/hash). The literal string `null`
 *     is an opaque origin (sandboxed iframe / `data:` URL) and is refused.
 *     A native shell origin is the installed app, not the server's host, so
 *     it is admitted here instead of compared to that authority;
 *  4. otherwise ok. Non-browser loopback tools and the LAN opt-in (which may
 *     carry neither `Origin` nor `Sec-Fetch-Site`) pass here.
 *
 * @param {{hostHeader?: string, protocol?: string, origin?: string, secFetchSite?: string, proxyHeaders?: Record<string,string>, trustNativeClients?: boolean}} req
 * @returns {{ok: true} | {ok: false, status: 403, error: string}}
 */
export function admitSameSiteRequest({
  hostHeader,
  protocol = 'http:',
  origin,
  secFetchSite,
  proxyHeaders = {},
  trustNativeClients = false,
} = {}) {
  const native = isNativeAppOrigin(origin);
  // (1) A request carrying reverse-proxy / CDN forwarding headers did not
  // originate on this machine, whatever its socket says. A hosted deploy
  // (Render adds these headers) can opt in for the installed app only.
  if (hasProxySignals(proxyHeaders) && !(trustNativeClients && native)) {
    return {
      ok: false,
      status: 403,
      error: 'Proxied requests are not accepted',
    };
  }
  // (2) The browser tells us when a request is cross-site. `none` is a typed
  // URL / bookmark; `same-origin` is the app itself. Anything else (cross-site,
  // same-site but cross-origin) is refused. The native shell is the app.
  const site = String(secFetchSite || '')
    .trim()
    .toLowerCase();
  if (site !== '' && site !== 'same-origin' && site !== 'none' && !native) {
    return {
      ok: false,
      status: 403,
      error: 'Cross-site requests are not accepted',
    };
  }
  // (3) If Origin is present it must exactly equal the request's own authority.
  if (!native && origin !== undefined && origin !== null && origin !== '') {
    if (origin === 'null') {
      return {
        ok: false,
        status: 403,
        error: 'Opaque origins are not accepted',
      };
    }
    const authority = requestAuthority(hostHeader, protocol);
    let parsedOrigin;
    try {
      parsedOrigin = new URL(String(origin));
    } catch {
      return { ok: false, status: 403, error: 'Unrecognized Origin refused' };
    }
    const exactOrigin =
      parsedOrigin.username === '' &&
      parsedOrigin.password === '' &&
      parsedOrigin.pathname === '/' &&
      parsedOrigin.search === '' &&
      parsedOrigin.hash === '' &&
      parsedOrigin.origin === authority;
    if (!exactOrigin) {
      return {
        ok: false,
        status: 403,
        error: 'Cross-origin requests are not accepted',
      };
    }
  }
  return { ok: true };
}
