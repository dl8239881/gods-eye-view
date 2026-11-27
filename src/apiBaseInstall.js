import { activeApiBase, installApiBase, isNativeShell } from './apiBase.js';
import { installDirectFeeds } from './native/directFeeds.js';
import { nativePageScrollBlocked } from './native/pageScroll.js';

// Evaluated before the rest of the app graph, so fetch bindings captured
// during later module init already go through the hosted-server prefix.
// Direct public feeds wrap that, and only when the installed app has no uplink.
installApiBase();
installDirectFeeds();
globalThis.__GEV_API_BASE__ = activeApiBase;

try {
  if (isNativeShell() && globalThis.document?.documentElement) {
    globalThis.document.documentElement.dataset.nativeApp = 'ios';
    globalThis.document.addEventListener(
      'touchmove',
      (event) => {
        if (nativePageScrollBlocked(event.target)) event.preventDefault();
      },
      { passive: false },
    );
  }
} catch {
  /* The document is optional in non-browser hosts. */
}
