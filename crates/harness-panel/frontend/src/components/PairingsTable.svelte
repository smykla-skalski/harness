<script lang="ts">
  import { formatRelative, formatTimestamp } from '../lib/format';
  import { handleLabel, readHandle } from '../lib/identity';
  import {
    liveCount,
    pairingCanUnpair,
    pairingChange,
    pairingIsLive,
    pairingSubject,
    pairingTone,
  } from '../lib/pairing-state';
  import type { PanelAccount, PanelPairing } from '../lib/types';
  import Chip from './Chip.svelte';
  import Plate from './Plate.svelte';

  const {
    pairings,
    accounts,
    showAccount,
    failure,
    onUnpair,
  }: {
    pairings: PanelPairing[];
    /** Only the owner holds these, and only the owner's table names an account. */
    accounts: PanelAccount[];
    showAccount: boolean;
    failure: string | null;
    onUnpair: (pairingId: string) => Promise<void>;
  } = $props();

  /**
   * Same cadence as the roster. Captured once, the clock would never move again
   * for as long as the page stayed open, so a row reading "claimed just now"
   * would go on saying it.
   */
  const AGE_TICK_MS = 30_000;

  let now = $state(Date.now());
  /** The row whose unpair has been asked for but not yet confirmed. */
  let confirming = $state<string | null>(null);
  let working = $state<string | null>(null);

  const live = $derived(liveCount(pairings));
  const byAccount = $derived(new Map(accounts.map((account) => [account.id, account])));

  $effect(() => {
    const tick = setInterval(() => {
      now = Date.now();
    }, AGE_TICK_MS);
    return () => {
      clearInterval(tick);
    };
  });

  // A row that leaves the list takes its half-finished confirmation with it,
  // which otherwise reappears on whichever row later reuses the id.
  $effect(() => {
    if (confirming !== null && !pairings.some((pairing) => pairing.pairing_id === confirming)) {
      confirming = null;
    }
  });

  function accountLabel(pairing: PanelPairing): string | null {
    if (!showAccount) {
      return null;
    }
    const account =
      pairing.account_id === undefined ? undefined : byAccount.get(pairing.account_id);
    if (account === undefined) {
      // A pairing the panel has no record of, or one whose account has since
      // been forgotten. Saying so is better than an empty gap that reads as a
      // row belonging to whoever is above it.
      return 'unattributed';
    }
    return handleLabel(readHandle(account.provider, account.login));
  }

  async function unpair(pairingId: string): Promise<void> {
    working = pairingId;
    try {
      await onUnpair(pairingId);
      confirming = null;
    } finally {
      working = null;
    }
  }
</script>

<Plate label="Paired devices">
  {#snippet status()}
    <span class="tally mono">{live} of {pairings.length} live</span>
  {/snippet}

  {#if failure !== null}
    <p class="failure">{failure}</p>
  {/if}

  {#if pairings.length === 0}
    <p class="dim">
      {showAccount
        ? 'Nothing has been paired through the panel yet'
        : 'You have not paired a device yet'}
    </p>
  {:else}
    <ul class="rows">
      {#each pairings as pairing (pairing.pairing_id)}
        {@const change = pairingChange(pairing)}
        {@const account = accountLabel(pairing)}
        <li class="row">
          <Chip tone={pairingTone(pairing.state)} dot={pairingIsLive(pairing.state)}>
            {pairing.state}
          </Chip>
          <div class="what">
            <p class="name">{pairingSubject(pairing)}</p>
            <!-- The relative time goes last because its width changes as it
                 ages, and anything after it would shift sideways on the tick. -->
            <p class="meta mono">
              {#if account !== null}
                {account}
                ·
              {/if}
              {pairing.device?.platform ?? pairing.role}
              ·
              <span title={formatTimestamp(change.at)}>
                {change.label}
                {formatRelative(change.at, now)}
              </span>
            </p>
          </div>

          {#if confirming === pairing.pairing_id}
            <div class="decide">
              <button
                class="btn btn-stop"
                disabled={working === pairing.pairing_id}
                onclick={() => unpair(pairing.pairing_id)}
              >
                {working === pairing.pairing_id ? 'Unpairing…' : 'Confirm'}
              </button>
              <button
                class="btn btn-quiet"
                disabled={working === pairing.pairing_id}
                onclick={() => (confirming = null)}
              >
                Cancel
              </button>
            </div>
          {:else if pairingCanUnpair(pairing.state)}
            <button class="btn unpair" onclick={() => (confirming = pairing.pairing_id)}>
              Unpair
            </button>
          {/if}
        </li>

        {#if confirming === pairing.pairing_id}
          <!-- Beneath the row rather than in a dialog, so what is about to be
               cut off stays on screen next to the control that does it. -->
          <li class="warn" role="status">
            {pairing.device === undefined
              ? 'This link can no longer be claimed. It cannot be undone, and pairing that device means generating another link'
              : 'This device loses its access immediately. It cannot be undone, and pairing it again means a new link'}
          </li>
        {/if}
      {/each}
    </ul>
  {/if}
</Plate>

<style>
  .tally {
    color: var(--dim);
    font-size: 0.6875rem;
    letter-spacing: 0.06em;
    text-transform: uppercase;
  }

  .rows {
    list-style: none;
    margin: 0;
    padding: 0;
  }

  /* A list rather than a data table: one control per subject, and it reflows
     onto a phone without either scrolling sideways or dropping the column a
     decision rests on. */
  .row {
    align-items: center;
    border-top: 1px solid var(--rule);
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem 0.75rem;
    padding: 0.75rem 0;
  }

  .row:first-child {
    border-top: 0;
    padding-top: 0;
  }

  /* Takes the slack so every control lines up on the right. */
  .what {
    flex: 1 1 10rem;
    min-width: 0;
  }

  .name {
    font-weight: 600;
    margin: 0;
    overflow-wrap: anywhere;
  }

  .meta {
    color: var(--dim);
    font-size: 0.6875rem;
    margin: 0.15rem 0 0;
    overflow-wrap: anywhere;
  }

  .decide {
    display: flex;
    flex: none;
    gap: 0.25rem;
  }

  .unpair {
    flex: none;
    width: 5.75rem;
  }

  /* Tinted rather than plain text: it sits between two rows and has to read as
     belonging to the one above it. */
  .warn {
    background: var(--stop-tint);
    border-radius: var(--r-well);
    color: var(--stop);
    font-size: 0.8125rem;
    margin: 0 0 0.25rem;
    padding: 0.5rem 0.75rem;
  }

  .failure {
    color: var(--stop);
    margin: 0 0 0.875rem;
  }
</style>
