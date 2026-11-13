import { activeApiBase, installApiBase, isNativeShell } from './apiBase.js';
import { installDirectFeeds } from './native/directFeeds.js';

// Evaluated before the rest of the app graph, so fetch bindings captured
// during later module init already go through the hosted-server prefix.
// Direct public feeds wrap that, and only when the installed app has no uplink.
installApiBase();
installDirectFeeds();
globalThis.__GEV_API_BASE__ = activeApiBase;

try {
  if (isNativeShell() && globalThis.document?.documentElement) {
    globalThis.document.documentElement.dataset.nativeApp = 'ios';
    const blockPageZoom = (event) => {
      if (event.target?.closest?.('#cesiumContainer')) return;
      event.preventDefault();
    };
    globalThis.document.addEventListener('gesturestart', blockPageZoom, {
      passive: false,
    });
    globalThis.document.addEventListener('gesturechange', blockPageZoom, {
      passive: false,
    });
  }
} catch {
  /* The document is optional in non-browser hosts. */
}
