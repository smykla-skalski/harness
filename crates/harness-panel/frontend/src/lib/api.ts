import { panelUrl } from './base';
import type { PanelAccount, PanelErrorBody, PanelViewer } from './types';

/** A panel response the caller cannot treat as data. */
export class PanelApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = 'PanelApiError';
  }
}

export interface PanelApi {
  /** The signed-in person, or `null` when the session is absent or expired. */
  fetchViewer(): Promise<PanelViewer | null>;
  /** Everyone who has signed in. Owner only; throws 403 for anyone else. */
  fetchAccounts(): Promise<PanelAccount[]>;
  signOut(): Promise<void>;
  signInUrl(): string;
}

type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export function createPanelApi(base: string, fetchImpl: FetchLike): PanelApi {
  const request = async (path: string, init?: RequestInit): Promise<Response> => {
    // `credentials` goes last so a caller's init cannot displace it. Every
    // route behind this helper is session-authenticated, and dropping the
    // cookie would read as being signed out rather than as a mistake.
    const response = await fetchImpl(panelUrl(base, path), {
      ...init,
      credentials: 'same-origin',
    });
    if (!response.ok) {
      throw await readError(response);
    }
    return response;
  };

  return {
    async fetchViewer(): Promise<PanelViewer | null> {
      const response = await fetchImpl(panelUrl(base, '/api/me'), {
        credentials: 'same-origin',
      });
      // Signing in is the whole point of the page, so "no session" is the
      // expected first state rather than a failure worth surfacing.
      if (response.status === 401) {
        return null;
      }
      if (!response.ok) {
        throw await readError(response);
      }
      return (await response.json()) as PanelViewer;
    },

    async fetchAccounts(): Promise<PanelAccount[]> {
      const response = await request('/api/accounts');
      const body = (await response.json()) as { accounts: PanelAccount[] };
      return body.accounts;
    },

    async signOut(): Promise<void> {
      await request('/auth/signout', { method: 'POST' });
    },

    signInUrl(): string {
      return panelUrl(base, '/auth/github/start');
    },
  };
}

async function readError(response: Response): Promise<PanelApiError> {
  let code = 'unknown';
  let message = `panel request failed with status ${response.status}`;
  try {
    const body = (await response.json()) as Partial<PanelErrorBody>;
    if (body.error?.code !== undefined) {
      code = body.error.code;
    }
    if (body.error?.message !== undefined && body.error.message !== '') {
      message = body.error.message;
    }
  } catch {
    // A proxy or a crash can answer with something that is not the panel's
    // error envelope; the status line is still worth reporting.
  }
  return new PanelApiError(response.status, code, message);
}
