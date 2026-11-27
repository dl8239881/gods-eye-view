/**
 * The installed app's page must not scroll. Cesium listens to pointer events
 * and does not cancel the touch stream, so iOS would pan the WKWebView and
 * then cancel the pointer mid-drag.
 * @param {EventTarget|null|undefined} target
 * @returns {boolean} True when the touch must not scroll the page.
 */
export function nativePageScrollBlocked(target) {
  const element =
    target?.nodeType === 1 ? target : target?.parentElement || null;
  if (!element?.closest) return true;
  return !element.closest('input, textarea, select, [contenteditable="true"]');
}
