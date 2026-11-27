/**
 * The installed app's native screens call `gevShell.apply(command)`.
 * The web view stays the globe; this module does not draw a page.
 */
import * as Cesium from 'cesium';
import { activeApiBase, clearApiBase, saveApiBase } from '../apiBase.js';
import { layerFeedState } from '../data/feedState.js';
import { loadDirectCameras } from './directFeeds.js';

const GROUPS = [
  [
    'Movement',
    [
      'satellites',
      'flights',
      'military',
      'local-adsb',
      'ais-live-vessels',
      'traffic',
      'transit',
      'bikeshare',
    ],
  ],
  ['Cameras', ['cctv', 'recent-imagery', 'street-level']],
  [
    'Infrastructure',
    [
      'alpr-cameras',
      'military-installations',
      'drone-airspace',
      'local-datacenters',
      'telegeography-submarine-cables',
      'local-dams',
      'sea-marks',
      'ski-pistes',
    ],
  ],
  [
    'Events',
    [
      'rocket-launches',
      'earthquakes',
      'local-firms',
      'fire-perimeters',
      'gnss-integrity',
      's2-ghostmaps',
      'shipwrecks',
      'news',
    ],
  ],
  ['Wildlife', ['wildlife-sightings']],
  [
    'Weather',
    [
      'air-quality',
      'wind',
      'weather-radar',
      'weather-satellite',
      'weather-lightning',
      'weather-cyclones',
    ],
  ],
  ['Utilities', ['directions', 'osm-places']],
  ['Audio', ['radio']],
];

const QUALITY = {
  low: { scale: 0.65, error: 8, cache: 48, fps: 24 },
  medium: { scale: 1, error: 4, cache: 80, fps: 30 },
  high: { scale: 1, error: 2, cache: 120, fps: 48 },
};

function plain(value) {
  try {
    return JSON.parse(JSON.stringify(value));
  } catch {
    return null;
  }
}

/** Machine status for a layer row. `off` is a disabled layer. */
export function layerNativeStatus(layer = {}) {
  const stats = layer.stats || {};
  const error = String(stats.error || stats.lastError || '');
  const needs =
    /needs server/i.test(error) ||
    stats.code === 'NEEDS_SERVER' ||
    stats.keyRequired === true;
  if (!layer.enabled) {
    return { status: 'off', detail: needs ? 'Needs server' : '' };
  }
  if (needs) return { status: 'needs-server', detail: 'Needs server' };
  if (layer.lifecycleState === 'enabling' || stats.loading) {
    return { status: 'loading', detail: '' };
  }
  if (layerFeedState(stats) === 'unavailable') {
    return {
      status: 'unavailable',
      detail: error.slice(0, 180) || 'Unavailable',
    };
  }
  return { status: 'ok', detail: error.slice(0, 180) };
}

function subgroupsOf(controls) {
  const chips = Array.isArray(controls?.chips) ? controls.chips : [];
  const subgroups = [];
  for (const chip of chips) {
    if (!chip?.params || typeof chip.params !== 'object') continue;
    const params = plain(chip.params);
    const id = String(chip.id || chip.label || '').trim();
    if (!params || !id) continue;
    subgroups.push({
      id,
      label: String(chip.label || chip.id || 'Group'),
      active: chip.active === true,
      params,
    });
  }
  return subgroups;
}

function presentLayer(layer, controls) {
  const status = layerNativeStatus(layer);
  return {
    id: layer.id,
    name: String(layer.name || layer.id),
    enabled: Boolean(layer.enabled),
    status: status.status,
    detail: status.detail,
    subgroups: layer.enabled ? subgroupsOf(controls) : [],
  };
}

/**
 * Group the manager's layer list in the panel's order.
 * @param {object[]} layers Rows from the layer manager.
 * @param {Record<string, object>} [controlsById] `getRowControls()` by layer id.
 */
export function groupNativeLayers(layers, controlsById = {}) {
  const visible = (Array.isArray(layers) ? layers : []).filter(
    (layer) => layer && layer.showInTogglePanel !== false && layer.id,
  );
  const byId = new Map(
    visible.map((layer) => [
      layer.id,
      presentLayer(layer, controlsById[layer.id]),
    ]),
  );
  const used = new Set();
  const groups = [];
  for (const [name, ids] of GROUPS) {
    const rows = [];
    for (const id of ids) {
      const row = byId.get(id);
      if (!row) continue;
      used.add(id);
      rows.push(row);
    }
    if (rows.length) groups.push({ name, layers: rows });
  }
  const rest = visible
    .filter((layer) => !used.has(layer.id))
    .map((layer) => presentLayer(layer, controlsById[layer.id]));
  if (rest.length) groups.push({ name: 'More', layers: rest });
  return groups;
}

function readQuality() {
  try {
    const stored = globalThis.localStorage?.getItem('gev.quality');
    if (stored && QUALITY[stored]) return stored;
  } catch {
    /* Storage is optional. */
  }
  return 'medium';
}

function applyQuality(viewer, level) {
  const preset = QUALITY[level] || QUALITY.medium;
  const name = QUALITY[level] ? level : 'medium';
  try {
    globalThis.localStorage?.setItem('gev.quality', name);
  } catch {
    /* Ignore a private-mode store. */
  }
  const ratio = Math.max(1, globalThis.devicePixelRatio || 1);
  viewer.resolutionScale = Math.min(preset.scale, 2 / ratio);
  viewer.targetFrameRate = preset.fps;
  const globe = viewer.scene?.globe;
  if (globe) {
    globe.maximumScreenSpaceError = preset.error;
    globe.tileCacheSize = preset.cache;
  }
  viewer.scene?.requestRender?.();
  return name;
}

function fly(viewer, lat, lon, range) {
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return false;
  const height = Number.isFinite(range) && range > 200 ? range : 18000;
  viewer.camera.flyTo({
    destination: Cesium.Cartesian3.fromDegrees(lon, lat, height),
    duration: 1.4,
    complete: () => viewer.scene.requestRender(),
  });
  viewer.scene.requestRender();
  return true;
}

function textOf(value) {
  if (typeof value === 'string') return value;
  if (value && typeof value.getValue === 'function') {
    try {
      return value.getValue(Cesium.JulianDate.now());
    } catch {
      return '';
    }
  }
  return '';
}

function plainText(value) {
  return String(textOf(value) || '')
    .replace(/<[^>]+>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 500);
}

function post(message) {
  try {
    globalThis.webkit?.messageHandlers?.gev?.postMessage(message);
  } catch {
    /* The native handler is absent in a browser. */
  }
}

function watchPicks(viewer) {
  const canvas = viewer.canvas;
  if (!canvas) return;
  const pointers = new Set();
  let start = null;
  canvas.addEventListener(
    'pointerdown',
    (event) => {
      pointers.add(event.pointerId);
      start =
        pointers.size === 1
          ? {
              id: event.pointerId,
              x: event.clientX,
              y: event.clientY,
              t: Date.now(),
            }
          : null;
    },
    { passive: true },
  );
  canvas.addEventListener(
    'pointercancel',
    (event) => {
      pointers.delete(event.pointerId);
      start = null;
    },
    { passive: true },
  );
  canvas.addEventListener(
    'pointerup',
    (event) => {
      const origin = start;
      pointers.delete(event.pointerId);
      if (!origin || origin.id !== event.pointerId || pointers.size) return;
      const dx = event.clientX - origin.x;
      const dy = event.clientY - origin.y;
      if (dx * dx + dy * dy > 144 || Date.now() - origin.t > 500) return;
      const rect = canvas.getBoundingClientRect();
      const picked = viewer.scene.pick(
        new Cesium.Cartesian2(
          event.clientX - rect.left,
          event.clientY - rect.top,
        ),
      );
      const entity = picked?.id;
      if (!entity) return;
      if (typeof entity === 'string') {
        post({
          type: 'pick',
          title: entity.slice(0, 140),
          detail: '',
          lat: null,
          lon: null,
        });
        return;
      }
      if (typeof entity !== 'object' || (!entity.name && !entity.id)) return;
      let lat = null;
      let lon = null;
      try {
        const position = entity.position?.getValue?.(Cesium.JulianDate.now());
        if (position) {
          const cartographic = Cesium.Cartographic.fromCartesian(position);
          lat = Cesium.Math.toDegrees(cartographic.latitude);
          lon = Cesium.Math.toDegrees(cartographic.longitude);
        }
      } catch {
        /* A primitive without a cartesian position still has a name. */
      }
      post({
        type: 'pick',
        title: String(entity.name || entity.id || 'Selection').slice(0, 140),
        detail: plainText(entity.description),
        lat,
        lon,
      });
    },
    { passive: true },
  );
}

async function searchPlaces(query) {
  const q = String(query || '').trim();
  if (q.length < 2) return [];
  const url = new URL('https://nominatim.openstreetmap.org/search');
  url.searchParams.set('format', 'jsonv2');
  url.searchParams.set('limit', '6');
  url.searchParams.set('q', q);
  const response = await fetch(url, {
    headers: { Accept: 'application/json' },
  });
  const rows = await response.json();
  if (!Array.isArray(rows)) return [];
  return rows
    .map((row) => ({
      name: String(row.display_name || q),
      lat: Number(row.lat),
      lon: Number(row.lon),
    }))
    .filter((row) => Number.isFinite(row.lat) && Number.isFinite(row.lon))
    .slice(0, 6);
}

function presentCamera(camera) {
  return {
    id: String(camera.id),
    name: String(camera.name || camera.id),
    city: String(camera.city || ''),
    provider: String(camera.provider || ''),
    lat: Number(camera.lat),
    lon: Number(camera.lon),
    image:
      typeof camera.directImageUrl === 'string' ? camera.directImageUrl : '',
  };
}

/**
 * Publish the bridge after the globe exists.
 * @param {object} application Started application.
 */
export function installShellBridge(application) {
  const components = application?.getComponents?.();
  const manager = components?.data?.dataManager;
  const viewer = components?.scene?.viewer;
  if (!manager || !viewer) return false;

  function snapshot() {
    const controlsById = {};
    for (const layer of manager.getAll()) {
      const module = manager.layers.get(layer.id)?.module;
      if (typeof module?.getRowControls !== 'function') continue;
      try {
        controlsById[layer.id] = module.getRowControls() || null;
      } catch {
        controlsById[layer.id] = null;
      }
    }
    return { groups: groupNativeLayers(manager.getAll(), controlsById) };
  }

  async function apply(command) {
    const op = command?.op;
    if (op === 'layers') return snapshot();
    if (op === 'setLayer') {
      await manager.setEnabled(String(command.id), Boolean(command.enabled), {
        origin: 'user',
      });
      return snapshot();
    }
    if (op === 'params') {
      manager.setLayerParams(String(command.id), command.params || {}, {
        origin: 'user',
      });
      return snapshot();
    }
    if (op === 'search') return searchPlaces(command.q);
    if (op === 'cameras') {
      const cameras = await loadDirectCameras(globalThis.fetch);
      return cameras.slice(0, 80).map(presentCamera);
    }
    if (op === 'fly') {
      return {
        ok: fly(
          viewer,
          Number(command.lat),
          Number(command.lon),
          Number(command.range),
        ),
      };
    }
    if (op === 'uplink') {
      const url = String(command.url || '').trim();
      if (url) saveApiBase(url);
      else clearApiBase();
      globalThis.location?.reload?.();
      return { ok: true };
    }
    if (op === 'quality')
      return { quality: applyQuality(viewer, command.level) };
    if (op === 'settings') {
      return { uplink: activeApiBase() || '', quality: readQuality() };
    }
    return { error: 'unknown' };
  }

  globalThis.gevShell = { apply };
  applyQuality(viewer, readQuality());
  watchPicks(viewer);
  if (globalThis.document?.documentElement) {
    globalThis.document.documentElement.dataset.nativeReady = '1';
  }
  return true;
}
