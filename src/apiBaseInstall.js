import { installApiBase, isNativeShell } from './apiBase.js';

// Evaluated before the rest of the app graph, so fetch bindings captured
// during later module init already go through the hosted-server prefix.
installApiBase();

try {
  if (isNativeShell() && globalThis.document?.documentElement) {
    globalThis.document.documentElement.dataset.nativeApp = 'ios';
  }
} catch {
  /* The document is optional in non-browser hosts. */
}
