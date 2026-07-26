/**
 * Reading a pairing's state the way the page presents it.
 *
 * The daemon owns this vocabulary and the panel passes it through as a string,
 * so everything here treats an unfamiliar state as something to show plainly
 * rather than as an error. A state added to the daemon should reach the page as
 * itself, not as a blank row or a crash.
 */

import type { ChipTone } from '../components/Chip.svelte';
import type { PanelPairing } from './types';

/**
 * States that can no longer become anything else.
 *
 * A revoked pairing is cut off and an expired one lapsed before anyone claimed
 * it, so neither has an unpair worth offering. Anything else, including a state
 * this build has not heard of, keeps the control: refusing to offer it would
 * strand whatever it turns out to be.
 */
const FINISHED = new Set(['expired', 'revoked']);

/**
 * Tone by what the state means, not by which state it is.
 *
 * Brass marks a live credential nobody has spent yet, matching the link card
 * that produced it. Green is a pairing doing its job, red one that was cut off,
 * and grey one that is over.
 */
export function pairingTone(state: string): ChipTone {
  switch (state) {
    case 'pending':
      return 'signal';
    case 'claimed':
    case 'active':
      return 'clear';
    case 'revoked':
      return 'stop';
    case 'expired':
      return 'neutral';
    default:
      return 'neutral';
  }
}

/**
 * Whether the state is something happening now rather than a fixed attribute,
 * which is what the chip's dot means.
 *
 * A claimed pairing whose device has never connected deliberately has no dot:
 * telling it from an active one is the point of having both.
 */
export function pairingIsLive(state: string): boolean {
  return state === 'pending' || state === 'active';
}

/** Whether this pairing still has an unpair worth offering. */
export function pairingCanUnpair(state: string): boolean {
  return !FINISHED.has(state);
}

/** The last thing that happened to a pairing, and when. */
export interface PairingChange {
  label: string;
  at: string;
}

/**
 * When the pairing last changed, and what the change was.
 *
 * Always a moment in the past, so it renders as an age. Each state falls back
 * to when the link was created, because a row that cannot say what happened to
 * it can still say when it started, and a blank column would read as a bug
 * rather than as a missing timestamp.
 */
export function pairingChange(pairing: PanelPairing): PairingChange {
  const created = { label: 'created', at: pairing.created_at };
  switch (pairing.state) {
    case 'revoked':
      // From whichever end carries it: a link withdrawn before any claim has no
      // device to read it from.
      return at('revoked', pairing.revoked_at ?? pairing.device?.revoked_at, created);
    case 'expired':
      return at('expired', pairing.expires_at, created);
    case 'active':
      return at('last seen', pairing.device?.last_seen_at ?? pairing.claimed_at, created);
    case 'claimed':
      return at('claimed', pairing.claimed_at, created);
    default:
      return created;
  }
}

function at(label: string, value: string | undefined, fallback: PairingChange): PairingChange {
  return value === undefined ? fallback : { label, at: value };
}

/**
 * What the row is about: the device, or what happened instead of one.
 *
 * A pairing with no device is not a blank row, it is a link at some point in
 * its life, and saying which is what stops "no device" reading as a fault.
 */
export function pairingSubject(pairing: PanelPairing): string {
  if (pairing.device !== undefined) {
    return pairing.device.display_name;
  }
  switch (pairing.state) {
    case 'pending':
      return 'Waiting for a device';
    case 'expired':
      return 'Never claimed';
    case 'revoked':
      return 'Withdrawn before it was claimed';
    default:
      return 'Unclaimed link';
  }
}

/** How many of these are doing something right now, for the plate's header. */
export function liveCount(pairings: PanelPairing[]): number {
  return pairings.filter((pairing) => pairingIsLive(pairing.state)).length;
}
