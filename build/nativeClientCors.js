import { isNativeAppOrigin } from '../src/localRequestGate.mjs';

/**
 * CORS for the installed app. A browser page cannot send
 * `Origin: capacitor://localhost` or `ionic://localhost`, so reflecting that
 * exact origin does not open the API to other websites. Same-origin web
 * traffic sends no native Origin and receives no CORS headers.
 */

const ALLOW_METHODS = 'GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS';
const ALLOW_HEADERS = 'Accept, Authorization, Content-Type, Range';
const EXPOSE_HEADERS =
  'Accept-Ranges, Content-Length, Content-Range, Retry-After';

function isApiRequest(url) {
  const path = String(url || '/')
    .split(/[?#]/, 1)[0]
    .replace(/\\/g, '/');
  return /^\/api(?:$|[/.])/i.test(path);
}

/**
 * Set native-shell CORS headers on an `/api` response.
 * @param {import('node:http').IncomingMessage} req
 * @param {import('node:http').ServerResponse} res
 * @returns {boolean} True when an OPTIONS preflight was answered.
 */
export function applyNativeClientCors(req, res) {
  if (!isApiRequest(req?.url)) return false;
  const origin = String(req?.headers?.origin || '');
  if (!isNativeAppOrigin(origin)) return false;
  res.setHeader('Access-Control-Allow-Origin', origin);
  res.setHeader('Vary', 'Origin');
  res.setHeader('Access-Control-Allow-Methods', ALLOW_METHODS);
  res.setHeader('Access-Control-Allow-Headers', ALLOW_HEADERS);
  res.setHeader('Access-Control-Expose-Headers', EXPOSE_HEADERS);
  res.setHeader('Access-Control-Max-Age', '600');
  if (String(req.method || '').toUpperCase() !== 'OPTIONS') return false;
  res.statusCode = 204;
  res.setHeader('Content-Length', '0');
  res.end();
  return true;
}

/** Vite middleware. Runs after the Host check so a refused host gets no CORS. */
export function nativeClientCorsPlugin() {
  const middleware = (req, res, next) => {
    if (applyNativeClientCors(req, res)) return;
    next();
  };
  const install = (server) => {
    server.middlewares.use(middleware);
  };
  return {
    name: 'native-client-cors',
    enforce: 'pre',
    configureServer: install,
    configurePreviewServer: install,
  };
}
