import { describe, expect, it } from 'vitest';

import { PanelApiError, createPanelApi } from '../src/lib/api';

interface RecordedCall {
  url: string;
  init?: RequestInit;
}

function stubFetch(responses: Response[]): {
  calls: RecordedCall[];
  fetch: (input: string, init?: RequestInit) => Promise<Response>;
} {
  const calls: RecordedCall[] = [];
  const queue = [...responses];
  return {
    calls,
    fetch: (url: string, init?: RequestInit) => {
      calls.push({ url, init });
      const next = queue.shift();
      if (next === undefined) {
        throw new Error(`unexpected request to ${url}`);
      }
      return Promise.resolve(next);
    },
  };
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

const VIEWER = {
  account: {
    id: 'acc_1',
    provider: 'github',
    subject_id: '4242',
    login: 'ada',
    display_name: 'Ada Lovelace',
    avatar_url: null,
    first_seen_at: '2026-07-25T10:00:00Z',
    last_seen_at: '2026-07-25T11:00:00Z',
  },
  is_owner: false,
};

describe('fetchViewer', () => {
  it('returns the signed-in account', async () => {
    const stub = stubFetch([jsonResponse(200, VIEWER)]);
    const api = createPanelApi('/panel', stub.fetch);

    await expect(api.fetchViewer()).resolves.toEqual(VIEWER);
    expect(stub.calls[0]?.url).toBe('/panel/api/me');
    expect(stub.calls[0]?.init?.credentials).toBe('same-origin');
  });

  // Arriving without a session is the ordinary first visit, so it must not
  // reach the page as an error banner.
  it('reports no session rather than failing', async () => {
    const stub = stubFetch([
      jsonResponse(401, { error: { code: 'unauthenticated', message: 'sign in first' } }),
    ]);
    const api = createPanelApi('/panel', stub.fetch);

    await expect(api.fetchViewer()).resolves.toBeNull();
  });

  it('surfaces any other failure with the panel error code', async () => {
    const stub = stubFetch([
      jsonResponse(500, { error: { code: 'storage', message: 'account store is unavailable' } }),
    ]);
    const api = createPanelApi('/panel', stub.fetch);

    await expect(api.fetchViewer()).rejects.toMatchObject({
      status: 500,
      code: 'storage',
      message: 'account store is unavailable',
    });
  });
});

describe('fetchAccounts', () => {
  it('unwraps the account list', async () => {
    const stub = stubFetch([jsonResponse(200, { accounts: [VIEWER.account] })]);
    const api = createPanelApi('/panel', stub.fetch);

    await expect(api.fetchAccounts()).resolves.toEqual([VIEWER.account]);
    expect(stub.calls[0]?.url).toBe('/panel/api/accounts');
  });

  it('rejects when the viewer is not the owner', async () => {
    const stub = stubFetch([
      jsonResponse(403, { error: { code: 'forbidden', message: 'owner only' } }),
    ]);
    const api = createPanelApi('/panel', stub.fetch);

    await expect(api.fetchAccounts()).rejects.toBeInstanceOf(PanelApiError);
  });
});

describe('signOut', () => {
  it('posts to the sign-out route', async () => {
    const stub = stubFetch([new Response(null, { status: 204 })]);
    const api = createPanelApi('/panel', stub.fetch);

    await api.signOut();

    expect(stub.calls[0]?.url).toBe('/panel/auth/signout');
    expect(stub.calls[0]?.init?.method).toBe('POST');
  });
});

// Every route behind the client is session-authenticated, so a request that
// went out without the cookie would read as being signed out rather than as a
// mistake.
describe('credentials', () => {
  it('are sent on every request the client makes', async () => {
    const stub = stubFetch([
      jsonResponse(200, VIEWER),
      jsonResponse(200, { accounts: [] }),
      new Response(null, { status: 204 }),
    ]);
    const api = createPanelApi('/panel', stub.fetch);

    await api.fetchViewer();
    await api.fetchAccounts();
    await api.signOut();

    expect(stub.calls).toHaveLength(3);
    for (const call of stub.calls) {
      expect(call.init?.credentials).toBe('same-origin');
    }
  });
});

describe('signInUrl', () => {
  it('points at the start route under the mount point', () => {
    expect(createPanelApi('/pairing', stubFetch([]).fetch).signInUrl()).toBe(
      '/pairing/auth/github/start',
    );
  });
});

// A reverse proxy or a crashed process can answer with something that is not
// the panel's envelope; the reader still needs to see that the call failed.
describe('non-envelope failures', () => {
  it('falls back to the status line', async () => {
    const stub = stubFetch([new Response('<html>502</html>', { status: 502 })]);
    const api = createPanelApi('/panel', stub.fetch);

    await expect(api.fetchAccounts()).rejects.toMatchObject({
      status: 502,
      code: 'unknown',
      message: 'panel request failed with status 502',
    });
  });
});
