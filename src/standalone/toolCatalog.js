/**
 * The address tools use for this page. An HTTP(S) page is its origin. The
 * Capacitor and Ionic shells have an opaque origin (`"null"`), so the shell
 * scheme and host are kept instead.
 * @param {string} baseURI `document.baseURI`
 * @returns {string}
 */
export function appPageAddress(baseURI) {
  const url = new URL(baseURI);
  if (url.origin !== 'null') return url.origin;
  return `${url.protocol}//${url.host}/`;
}

/** The standalone tool catalog for voice, loaded the first time voice needs it. */

let pending = null;

export function loadToolCatalog() {
  pending ??= Promise.all([
    import('../tools/index.js'),
    import('../tools/services.js'),
  ]).then(
    ([
      { composeCatalog, coreTools, catalogForSurface },
      { createToolServices },
    ]) =>
      catalogForSurface(
        composeCatalog({
          tools: coreTools,
          services: createToolServices({
            fetchImpl: (...args) => globalThis.fetch(...args),
            appUrl: appPageAddress(globalThis.document.baseURI),
          }),
        }),
        'voice',
      ),
  );
  pending.catch(() => {
    pending = null;
  });
  return pending;
}
