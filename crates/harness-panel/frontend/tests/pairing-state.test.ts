import { describe, expect, it } from 'vitest';

import {
  liveCount,
  pairingCanUnpair,
  pairingChange,
  pairingIsLive,
  pairingSubject,
  pairingTone,
} from '../src/lib/pairing-state';
import type { PanelPairing } from '../src/lib/types';

function pairing(overrides: Partial<PanelPairing> = {}): PanelPairing {
  return {
    pairing_id: 'pair-1',
    state: 'pending',
    role: 'operator',
    created_at: '2026-07-26T10:00:00Z',
    expires_at: '2026-07-26T10:10:00Z',
    ...overrides,
  };
}

describe('pairingTone', () => {
  // Brass is what the panel uses for anything holding a live credential, and an
  // unspent link is exactly that.
  it('marks an unclaimed link with the credential colour', () => {
    expect(pairingTone('pending')).toBe('signal');
  });

  it('marks a working pairing as clear and a cut-off one as stop', () => {
    expect(pairingTone('claimed')).toBe('clear');
    expect(pairingTone('active')).toBe('clear');
    expect(pairingTone('revoked')).toBe('stop');
    expect(pairingTone('expired')).toBe('neutral');
  });

  // The daemon owns this vocabulary. A state it grows should reach the page
  // looking unremarkable rather than crash the row or borrow a colour that
  // claims something about it.
  it('gives a state it has never heard of the plainest tone', () => {
    expect(pairingTone('quarantined')).toBe('neutral');
  });
});

describe('pairingIsLive', () => {
  // Telling these two apart is the point of having both: a claim that reached a
  // device which then never connected looks identical to a working pairing
  // unless something distinguishes them.
  it('separates a pairing in use from one merely claimed', () => {
    expect(pairingIsLive('active')).toBe(true);
    expect(pairingIsLive('claimed')).toBe(false);
  });

  it('counts an unclaimed link as live, because it still is', () => {
    expect(pairingIsLive('pending')).toBe(true);
    expect(pairingIsLive('expired')).toBe(false);
    expect(pairingIsLive('revoked')).toBe(false);
  });
});

describe('pairingCanUnpair', () => {
  it('offers nothing for a pairing that is already over', () => {
    expect(pairingCanUnpair('revoked')).toBe(false);
    expect(pairingCanUnpair('expired')).toBe(false);
  });

  it('offers the control for everything still going', () => {
    expect(pairingCanUnpair('pending')).toBe(true);
    expect(pairingCanUnpair('claimed')).toBe(true);
    expect(pairingCanUnpair('active')).toBe(true);
  });

  // Refusing to offer it would strand whatever the state turns out to be, and
  // the daemon answers a revoke it cannot act on without doing any harm.
  it('keeps the control for a state it has never heard of', () => {
    expect(pairingCanUnpair('quarantined')).toBe(true);
  });
});

describe('pairingChange', () => {
  it('reports what last happened to each state', () => {
    expect(pairingChange(pairing())).toEqual({
      label: 'created',
      at: '2026-07-26T10:00:00Z',
    });
    expect(
      pairingChange(pairing({ state: 'claimed', claimed_at: '2026-07-26T10:01:00Z' })),
    ).toEqual({ label: 'claimed', at: '2026-07-26T10:01:00Z' });
    expect(pairingChange(pairing({ state: 'expired' }))).toEqual({
      label: 'expired',
      at: '2026-07-26T10:10:00Z',
    });
  });

  // Where the device is what moved, that is the fact the reader wants; the
  // claim is only when it started.
  it('prefers when an active device was last seen over when it claimed', () => {
    const seen = pairingChange(
      pairing({
        state: 'active',
        claimed_at: '2026-07-26T10:01:00Z',
        device: {
          client_id: 'device-1',
          display_name: "Ada's laptop",
          platform: 'macos',
          last_seen_at: '2026-07-26T10:05:00Z',
        },
      }),
    );

    expect(seen).toEqual({ label: 'last seen', at: '2026-07-26T10:05:00Z' });
  });

  // A link withdrawn before any claim has no device to read the stamp from, so
  // the pairing's own is the only one there is.
  it('takes a revocation from whichever end carries it', () => {
    expect(
      pairingChange(pairing({ state: 'revoked', revoked_at: '2026-07-26T10:30:00Z' })),
    ).toEqual({ label: 'revoked', at: '2026-07-26T10:30:00Z' });

    expect(
      pairingChange(
        pairing({
          state: 'revoked',
          device: {
            client_id: 'device-1',
            display_name: "Ada's laptop",
            platform: 'macos',
            revoked_at: '2026-07-26T10:31:00Z',
          },
        }),
      ),
    ).toEqual({ label: 'revoked', at: '2026-07-26T10:31:00Z' });
  });

  // A blank column would read as a bug rather than as a stamp the daemon did
  // not send, and every pairing has a creation time.
  it('falls back to when the link was created rather than to nothing', () => {
    expect(pairingChange(pairing({ state: 'claimed' }))).toEqual({
      label: 'created',
      at: '2026-07-26T10:00:00Z',
    });
    expect(pairingChange(pairing({ state: 'quarantined' }))).toEqual({
      label: 'created',
      at: '2026-07-26T10:00:00Z',
    });
  });
});

describe('pairingSubject', () => {
  it('names the device once there is one', () => {
    expect(
      pairingSubject(
        pairing({
          state: 'active',
          device: { client_id: 'device-1', display_name: "Ada's laptop", platform: 'macos' },
        }),
      ),
    ).toBe("Ada's laptop");
  });

  // Without this the row would be blank, and a blank row reads as a fault
  // rather than as a link at a point in its life.
  it('says what happened instead of a device when there is none', () => {
    expect(pairingSubject(pairing())).toBe('Waiting for a device');
    expect(pairingSubject(pairing({ state: 'expired' }))).toBe('Never claimed');
    expect(pairingSubject(pairing({ state: 'revoked' }))).toBe('Withdrawn before it was claimed');
    expect(pairingSubject(pairing({ state: 'quarantined' }))).toBe('Unclaimed link');
  });
});

describe('liveCount', () => {
  it('counts only what is doing something now', () => {
    expect(
      liveCount([
        pairing({ pairing_id: 'a', state: 'active' }),
        pairing({ pairing_id: 'b', state: 'pending' }),
        pairing({ pairing_id: 'c', state: 'claimed' }),
        pairing({ pairing_id: 'd', state: 'revoked' }),
      ]),
    ).toBe(2);
    expect(liveCount([])).toBe(0);
  });
});
