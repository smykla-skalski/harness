/**
 * The build-time stand-in for the panel's mount point.
 *
 * Vite bakes `base` into the emitted asset URLs, but the mount point is a
 * runtime flag, so the build uses this sentinel and the serving binary
 * substitutes the configured prefix into `index.html`. Under `vite dev` no
 * substitution happens and the sentinel is the real mount point, which is why
 * reading it back is enough in both cases.
 */
export const BASE_PATH_SENTINEL = '/__harness_panel_base__';

const BASE_META_NAME = 'harness-panel-base';

/** Read the mount point the serving binary injected into `index.html`. */
export function readBasePath(source: Document): string {
  const meta = source.querySelector(`meta[name="${BASE_META_NAME}"]`);
  const content = meta?.getAttribute('content');
  if (content === null || content === undefined || content === '') {
    throw new Error(`the panel page is missing its <meta name="${BASE_META_NAME}"> element`);
  }
  return normalizeBasePath(content);
}

/**
 * Reduce a mount point to the one spelling the URL builder expects: a leading
 * slash and no trailing one, so joining never produces `//` or a bare relative
 * path that would resolve against whatever route the browser is showing.
 */
export function normalizeBasePath(raw: string): string {
  const trimmed = raw.trim().replace(/\/+$/, '');
  if (trimmed === '') {
    return '';
  }
  return trimmed.startsWith('/') ? trimmed : `/${trimmed}`;
}

/** Build an absolute path under the panel's mount point. */
export function panelUrl(base: string, path: string): string {
  const suffix = path.startsWith('/') ? path : `/${path}`;
  return `${normalizeBasePath(base)}${suffix}`;
}
