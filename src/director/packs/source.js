import { PACK_LIMITS, validateAssetPath } from './manifest.js';

/**
 * A directory the app itself serves. HTTP(S) covers the web app. The
 * Capacitor and Ionic shells serve the built files from `capacitor://localhost`
 * and `ionic://localhost`; WKWebView cannot register `https` as that scheme.
 * Scene files still cannot replace this origin or escape its path.
 * @param {URL} url
 * @returns {boolean}
 */
function isAssetDirectory(url) {
  if (
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    !url.pathname.endsWith('/')
  )
    return false;
  if (url.protocol === 'https:' || url.protocol === 'http:') return true;
  const host = url.hostname.toLowerCase();
  return (
    (url.protocol === 'capacitor:' || url.protocol === 'ionic:') &&
    host === 'localhost'
  );
}

/** Register a fixed asset directory. Scene files cannot replace its origin or escape its path. */
export function createAssetDirectorySource({
  baseUrl,
  fetchImpl = globalThis.fetch,
}) {
  const base = new URL(baseUrl);
  if (!isAssetDirectory(base))
    throw new TypeError(
      'Asset source requires an explicit HTTP(S) directory URL',
    );
  return async ({ path, signal, maxBytes = PACK_LIMITS.bytes }) => {
    validateAssetPath(path);
    signal?.throwIfAborted();
    const response = await fetchImpl(new URL(path, base).href, {
      signal,
      credentials: 'omit',
      redirect: 'error',
      referrerPolicy: 'no-referrer',
      cache: 'no-store',
    });
    if (!response.ok) {
      await response.body?.cancel().catch(() => {});
      throw new Error('Asset unavailable');
    }
    const reader = response.body?.getReader();
    if (!reader) throw new Error('Asset stream unavailable');
    const chunks = [];
    let length = 0;
    try {
      if (Number(response.headers.get('content-length')) > maxBytes)
        throw new Error('Asset exceeds byte limit');
      for (;;) {
        signal?.throwIfAborted();
        const { done, value } = await reader.read();
        signal?.throwIfAborted();
        if (done) break;
        length += value.byteLength;
        if (length > maxBytes) throw new Error('Asset exceeds byte limit');
        chunks.push(value);
      }
    } finally {
      await reader.cancel().catch(() => {});
      reader.releaseLock();
    }
    // Cleanup awaits too; a cancel during it must still discard the asset.
    signal?.throwIfAborted();
    const bytes = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return {
      bytes,
      mimeType: (response.headers.get('content-type') || '')
        .split(';')[0]
        .trim()
        .toLowerCase(),
    };
  };
}
