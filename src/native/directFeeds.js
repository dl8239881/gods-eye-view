/**
 * Public feeds for the installed app when no hosted server is configured.
 * The WebView's own origin has no `/api` proxies, so those paths are fetched
 * from the public upstream and shaped the way the layers already read them.
 * Anything that needs a server-side key answers with a JSON error instead of
 * the app's HTML page.
 */
import { activeApiBase, isNativeShell } from '../apiBase.js';
import { normalizeAdsbLolPointResponse } from '../data/adsbLolFallback.js';
import {
  celestrakSatcatUrl,
  celestrakTleUrl,
  launchLibraryRecentUrl,
} from '../data/spaceProviderRequests.js';

export const NEEDS_SERVER_MESSAGE = 'Needs server, set UPLINK';

const CELESTRAK_GROUPS = new Set([
  'stations',
  'visual',
  'gps-ops',
  'glo-ops',
  'galileo',
  'geo',
  'starlink',
  'resource',
  'weather',
  'planet',
  'sar',
  'science',
  'active',
]);

const USER_AGENT =
  'gods-eye-view-ios/0.1 (+https://github.com/dl8239881/gods-eye-view)';

/** True on the installed app while UPLINK / VITE_API_BASE is unset. */
export function useDirectFeeds() {
  return isNativeShell() && !activeApiBase();
}

function jsonResponse(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      ...headers,
    },
  });
}

function textResponse(body, status = 200, headers = {}) {
  return new Response(body, {
    status,
    headers: { 'content-type': 'text/plain; charset=utf-8', ...headers },
  });
}

export function needsServerResponse() {
  return jsonResponse(
    { error: NEEDS_SERVER_MESSAGE, code: 'NEEDS_SERVER' },
    503,
  );
}

function apiPath(input) {
  const raw = typeof input === 'string' ? input : input?.url;
  if (!raw) return null;
  let url;
  try {
    url = new URL(raw, 'https://app.invalid');
  } catch {
    return null;
  }
  if (url.protocol === 'https:' || url.protocol === 'http:') {
    if (url.hostname !== 'app.invalid' && url.hostname !== 'localhost')
      return null;
  }
  const path = url.pathname;
  if (path !== '/api' && !path.startsWith('/api/')) return null;
  return { path, search: url.searchParams };
}

async function readJson(response) {
  const type = String(response.headers?.get?.('content-type') || '');
  if (!response.ok || !/json/i.test(type)) return null;
  try {
    return await response.json();
  } catch {
    return null;
  }
}

function pinHttps(raw, host) {
  const text = String(raw || '').trim();
  if (!text) return '';
  let url;
  try {
    url = new URL(text);
  } catch {
    return '';
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return '';
  url.protocol = 'https:';
  if (url.hostname !== host) return '';
  return url.href;
}

function camera(record) {
  return {
    headingDeg: 0,
    headingConfidence: 'low',
    pitchDeg: -18,
    fovDeg: 44,
    rangeM: 145,
    mountHeightM: 8,
    groundElevationM: 20,
    feedType: 'image',
    ...record,
    url: record.directImageUrl,
    directImageUrl: record.directImageUrl,
  };
}

function nearest(cameras, limit, anchor) {
  const ranked = cameras
    .map((item) => {
      const dLat = item.lat - anchor.lat;
      const dLon = item.lon - anchor.lon;
      return { item, score: dLat * dLat + dLon * dLon };
    })
    .sort((a, b) => a.score - b.score);
  return ranked.slice(0, limit).map((entry) => entry.item);
}

async function loadNsw(fetchImpl, signal) {
  const response = await fetchImpl(
    'https://data.livetraffic.com/cameras/traffic-cam.json',
    { signal, headers: { Accept: 'application/json' } },
  );
  const body = await readJson(response);
  const features = Array.isArray(body?.features) ? body.features : [];
  const cameras = [];
  for (const feature of features) {
    const id = String(feature?.id || '').trim();
    const coords = feature?.geometry?.coordinates;
    const lon = coords?.[0];
    const lat = coords?.[1];
    if (!id || typeof lat !== 'number' || typeof lon !== 'number') continue;
    if (lat > -28 || lat < -38 || lon < 149 || lon > 154) continue;
    const image = pinHttps(
      feature?.properties?.href,
      'webcams.transport.nsw.gov.au',
    );
    if (!image) continue;
    const props = feature.properties || {};
    cameras.push(
      camera({
        id: `nsw-${id}`,
        name: String(props.view || props.title || `NSW ${id}`).slice(0, 140),
        city: String(props.region || 'New South Wales').replace(/_/g, ' '),
        cityId: 'sydney',
        provider: 'Live Traffic NSW',
        lat,
        lon,
        directImageUrl: image,
        sourceKind: 'nsw-livetraffic',
        sourceUrl: 'https://data.livetraffic.com/cameras/traffic-cam.json',
        license: 'Live Traffic NSW — Transport for NSW, CC BY 4.0',
      }),
    );
  }
  return nearest(cameras, 80, { lat: -33.8688, lon: 151.2093 });
}

async function loadTfl(fetchImpl, signal) {
  const response = await fetchImpl('https://api.tfl.gov.uk/Place/Type/JamCam', {
    signal,
    headers: { Accept: 'application/json' },
  });
  const places = await readJson(response);
  if (!Array.isArray(places)) return [];
  const cameras = [];
  for (const place of places) {
    const props = {};
    for (const property of place?.additionalProperties || []) {
      if (property?.key) props[property.key] = property.value;
    }
    if (String(props.available).toLowerCase() !== 'true') continue;
    const lat = Number(place?.lat);
    const lon = Number(place?.lon);
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;
    const image = pinHttps(props.imageUrl, 's3-eu-west-1.amazonaws.com');
    if (!image || !image.includes('jamcams.tfl.gov.uk')) continue;
    const rawId = String(place?.id || '').replace(/^JamCams_/, '');
    if (!rawId) continue;
    cameras.push(
      camera({
        id: `tfl-${rawId}`,
        name: String(place?.commonName || `JamCam ${rawId}`),
        city: 'London',
        cityId: 'london',
        provider: 'Transport for London',
        lat,
        lon,
        directImageUrl: image,
        sourceKind: 'tfl-open-data',
        sourceUrl: 'https://api.tfl.gov.uk/Place/Type/JamCam',
        license: 'Powered by TfL Open Data',
      }),
    );
  }
  return nearest(cameras, 80, { lat: 51.5074, lon: -0.1278 });
}

async function loadCaltrans(fetchImpl, signal) {
  const cameras = [];
  for (const district of [4, 7, 11, 3]) {
    const code = String(district).padStart(2, '0');
    const response = await fetchImpl(
      `https://cwwp2.dot.ca.gov/data/d${district}/cctv/cctvStatusD${code}.json`,
      { signal, headers: { Accept: 'application/json' } },
    );
    const payload = await readJson(response);
    const rows = Array.isArray(payload?.data) ? payload.data : [];
    for (const row of rows) {
      const cctv = row?.cctv;
      if (!cctv || String(cctv.inService).toLowerCase() !== 'true') continue;
      const lat = Number(cctv.location?.latitude);
      const lon = Number(cctv.location?.longitude);
      if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;
      const image = pinHttps(
        cctv.imageData?.static?.currentImageURL,
        'cwwp2.dot.ca.gov',
      );
      if (!image) continue;
      const name = String(
        cctv.location?.locationName || `Caltrans D${district}`,
      );
      cameras.push(
        camera({
          id: `ca-d${district}-${cameras.length}`,
          name,
          city: String(cctv.location?.nearbyPlace || `Caltrans D${district}`),
          cityId: district === 7 ? 'los-angeles' : 'san-francisco',
          provider: 'Caltrans',
          lat,
          lon,
          directImageUrl: image,
          sourceKind: 'caltrans-open-data',
          sourceUrl: 'https://cwwp2.dot.ca.gov/',
          license: 'Caltrans CCTV',
        }),
      );
    }
  }
  return cameras.slice(0, 120);
}

/** Keyless public camera catalogs the phone can read without the proxy. */
export async function loadDirectCameras(fetchImpl, signal) {
  const packs = await Promise.allSettled([
    loadNsw(fetchImpl, signal),
    loadTfl(fetchImpl, signal),
    loadCaltrans(fetchImpl, signal),
  ]);
  return packs.flatMap((result) =>
    result.status === 'fulfilled' ? result.value : [],
  );
}

async function celestrak(kind, group, fetchImpl, signal) {
  if (!CELESTRAK_GROUPS.has(group)) return textResponse('invalid group', 400);
  if (kind === 'satcat' && group === 'starlink') return needsServerResponse();
  const upstream =
    kind === 'satcat' ? celestrakSatcatUrl(group) : celestrakTleUrl(group);
  const response = await fetchImpl(upstream.href, {
    signal,
    headers: {
      Accept: 'text/plain',
      'User-Agent': USER_AGENT,
    },
  });
  const text = await response.text();
  const valid =
    kind === 'satcat' ? /^OBJECT_NAME,/.test(text) : /^1 /m.test(text);
  if (!response.ok || !valid) return textResponse('CelesTrak unreachable', 502);
  return textResponse(text, 200, {
    [kind === 'satcat' ? 'x-satcat-cache' : 'x-tle-cache']: 'MISS',
  });
}

async function flights(search, fetchImpl, signal) {
  const lat = Number(search.get('lat'));
  const lon = Number(search.get('lon'));
  if (Number.isFinite(lat) && Number.isFinite(lon)) {
    const upstream = `https://api.adsb.lol/v2/lat/${lat.toFixed(4)}/lon/${lon.toFixed(4)}/dist/250`;
    const response = await fetchImpl(upstream, {
      signal,
      headers: { Accept: 'application/json' },
    });
    const payload = await readJson(response);
    if (!payload) return needsServerResponse();
    return jsonResponse(normalizeAdsbLolPointResponse(payload), 200, {
      'x-flight-source': 'adsb.lol',
      'x-feed-source': 'adsb.lol',
      'x-flight-coverage': 'regional public snapshot',
    });
  }
  const response = await fetchImpl(
    'https://opensky-network.org/api/states/all?extended=1',
    { signal, headers: { Accept: 'application/json' } },
  );
  const payload = await readJson(response);
  if (!payload || !Array.isArray(payload.states)) return needsServerResponse();
  return jsonResponse(payload, 200, {
    'x-flight-source': 'OpenSky Network',
    'x-feed-source': 'OpenSky Network',
    'x-flight-coverage': 'worldwide upstream snapshot',
  });
}

async function military(fetchImpl, signal) {
  const response = await fetchImpl('https://api.adsb.lol/v2/mil', {
    signal,
    headers: { Accept: 'application/json' },
  });
  const payload = await readJson(response);
  if (!payload || !Array.isArray(payload.ac)) return needsServerResponse();
  return jsonResponse(payload, 200, {
    'x-feed-source': 'adsb.lol',
    'x-feed-cache': 'MISS',
  });
}

async function launches(fetchImpl, signal) {
  const upstream = launchLibraryRecentUrl(new Date());
  const response = await fetchImpl(upstream.href, {
    signal,
    headers: { Accept: 'application/json' },
  });
  const payload = await readJson(response);
  if (!payload || !Array.isArray(payload.results)) return needsServerResponse();
  return jsonResponse(payload, 200);
}

/**
 * Answer one same-origin `/api` request from a public feed.
 * @returns {Promise<Response|null>} Null when this request is not an API path.
 */
export async function routeDirectRequest(input, init, fetchImpl) {
  const route = apiPath(input);
  if (!route) return null;
  const { path, search } = route;
  const signal = init?.signal;
  if (path.startsWith('/api/celestrak-satcat/'))
    return celestrak(
      'satcat',
      decodeURIComponent(path.slice('/api/celestrak-satcat/'.length)),
      fetchImpl,
      signal,
    );
  if (path.startsWith('/api/celestrak/'))
    return celestrak(
      'tle',
      decodeURIComponent(path.slice('/api/celestrak/'.length)),
      fetchImpl,
      signal,
    );
  if (path === '/api/flights') return flights(search, fetchImpl, signal);
  if (path === '/api/military') return military(fetchImpl, signal);
  if (path === '/api/launches') return launches(fetchImpl, signal);
  if (path === '/api/cctv/sources') {
    const sources = await loadDirectCameras(fetchImpl, signal);
    return jsonResponse({ sources, trimmedPacks: [] });
  }
  if (path === '/api/cctv/health') {
    const sources = await loadDirectCameras(fetchImpl, signal);
    return jsonResponse({
      cameras: sources.map((source) => ({
        id: source.id,
        status: 'unknown',
        sourceKind: source.sourceKind,
        label: source.provider,
        message: '',
        updatedAt: Date.now(),
      })),
    });
  }
  return needsServerResponse();
}

/** Wrap fetch so a serverless native app never receives its own HTML for `/api`. */
export function installDirectFeeds(scope = globalThis) {
  if (!scope || scope.__gevDirectFeedsInstalled) return;
  Object.defineProperty(scope, '__gevDirectFeedsInstalled', { value: true });
  if (typeof scope.fetch !== 'function') return;
  const next = scope.fetch.bind(scope);
  scope.fetch = async (input, init) => {
    if (!useDirectFeeds()) return next(input, init);
    const direct = await routeDirectRequest(input, init, next);
    return direct || next(input, init);
  };
}
