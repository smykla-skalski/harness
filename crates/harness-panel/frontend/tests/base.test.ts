import { describe, expect, it } from 'vitest';

import { BASE_PATH_SENTINEL, normalizeBasePath, panelUrl, readBasePath } from '../src/lib/base';

function documentWithBase(content: string | null): Document {
  return {
    querySelector(selector: string) {
      if (selector !== 'meta[name="harness-panel-base"]') {
        return null;
      }
      return {
        getAttribute: () => content,
      };
    },
  } as unknown as Document;
}

describe('normalizeBasePath', () => {
  it('gives one spelling to the mount points an operator might write', () => {
    for (const raw of ['/panel', 'panel', '/panel/', ' /panel// ']) {
      expect(normalizeBasePath(raw)).toBe('/panel');
    }
  });

  it('treats a root mount as the empty prefix so joining never doubles the slash', () => {
    expect(normalizeBasePath('/')).toBe('');
    expect(panelUrl('/', '/api/me')).toBe('/api/me');
  });
});

describe('panelUrl', () => {
  it('builds an absolute path under the mount point', () => {
    expect(panelUrl('/panel', '/api/me')).toBe('/panel/api/me');
  });

  // A relative URL would resolve against whichever route the browser is
  // showing, so a deep link would send the request to the wrong path.
  it('stays absolute when the caller omits the leading slash', () => {
    expect(panelUrl('/panel', 'api/me')).toBe('/panel/api/me');
  });
});

describe('readBasePath', () => {
  it('reads the prefix the serving binary injected', () => {
    expect(readBasePath(documentWithBase('/pairing'))).toBe('/pairing');
  });

  // `vite dev` serves the unsubstituted page, where the sentinel is the real
  // mount point rather than a placeholder to work around.
  it('accepts the build-time sentinel as an ordinary prefix', () => {
    expect(readBasePath(documentWithBase(BASE_PATH_SENTINEL))).toBe(BASE_PATH_SENTINEL);
  });

  it('fails loudly when the page was not served by the panel', () => {
    expect(() => readBasePath(documentWithBase(null))).toThrow(/harness-panel-base/);
    expect(() => readBasePath(documentWithBase(''))).toThrow(/harness-panel-base/);
  });
});
