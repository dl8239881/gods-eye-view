import {
  ACTIVE_FRAME_REFRESH_MS,
  FRAME_ENDPOINT,
  MEDIA_ENDPOINT,
} from './sourcePolicy.js';
const FRAME_SOURCE_KINDS = new Set([
  'upstream-image',
  'hls-pull',
  'streetview',
  'synthetic',
]);
function safeNumber(value, fallback = NaN) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}
function withApiBase(url) {
  if (!url.startsWith('/')) return url;
  const read = globalThis.__GEV_API_BASE__;
  const base = typeof read === 'function' ? read() : '';
  return base ? `${base}${url}` : url;
}

function frameUrlFor(camera, refreshMs = ACTIVE_FRAME_REFRESH_MS) {
  const direct = String(camera?.directImageUrl || '').trim();
  if (/^https:\/\//.test(direct)) {
    const tick = Math.floor(
      Date.now() /
        Math.max(1000, safeNumber(refreshMs, ACTIVE_FRAME_REFRESH_MS)),
    );
    const sep = direct.includes('?') ? '&' : '?';
    return `${direct}${sep}gevts=${tick}`;
  }
  const cadenceMs = Math.max(
    1000,
    safeNumber(refreshMs, ACTIVE_FRAME_REFRESH_MS),
  );
  const tick = Math.floor(Date.now() / cadenceMs);
  const params = new URLSearchParams({
    label: camera.name,
    city: camera.city,
    lat: camera.lat.toFixed(6),
    lon: camera.lon.toFixed(6),
    heading: String(Math.round(camera.headingDeg)),
    fov: String(Math.round(camera.fovDeg)),
    pitch: String(Math.round(camera.pitchDeg || -10)),
    ts: String(tick),
  });
  return withApiBase(
    `${FRAME_ENDPOINT}/${encodeURIComponent(camera.id)}?${params.toString()}`,
  );
}
function mediaUrlFor(camera) {
  return withApiBase(
    `${MEDIA_ENDPOINT}/${encodeURIComponent(camera.id)}?ts=${Math.floor(Date.now() / 15000)}`,
  );
}
/** Supply catalog/health records and the existing registered camera URL families. */
export function createCctvSource({
  fetchImpl = (...args) => globalThis.fetch(...args),
} = {}) {
  async function read(path, key, { signal } = {}) {
    signal?.throwIfAborted();
    const response = await fetchImpl(path, { cache: 'no-store', signal });
    if (!response.ok) throw new Error('Camera source HTTP ' + response.status);
    let payload;
    try {
      payload = await response.json();
    } catch {
      throw new Error('Needs server, set UPLINK');
    }
    signal?.throwIfAborted();
    if (payload?.code === 'NEEDS_SERVER')
      throw new Error('Needs server, set UPLINK');
    if (!Array.isArray(payload?.[key]))
      throw new Error('Malformed camera ' + key + ' snapshot');
    return payload;
  }
  return {
    getCatalog(options) {
      return read('/api/cctv/sources', 'sources', options);
    },
    getHealth(options) {
      return read('/api/cctv/health', 'cameras', options);
    },
    getFrameUrl: frameUrlFor,
    getMediaUrl: mediaUrlFor,
    /** Read a registered frame and its provenance, including fallback frames. */
    async getFrame(camera, { signal } = {}) {
      signal?.throwIfAborted();
      const response = await fetchImpl(frameUrlFor(camera), {
        cache: 'no-store',
        signal,
      });
      if (!response.ok) throw new Error('Camera frame HTTP ' + response.status);
      const bytes = new Uint8Array(await response.arrayBuffer());
      signal?.throwIfAborted();
      const type = response.headers.get('content-type') || '';
      const sourceKind = response.headers.get('x-cctv-source');
      return {
        contentType: type.split(';')[0].trim().toLowerCase(),
        bytes,
        sourceKind: FRAME_SOURCE_KINDS.has(sourceKind) ? sourceKind : null,
      };
    },
  };
}
