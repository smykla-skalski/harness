<script lang="ts">
  import { formatRelative, formatTimestamp } from '../lib/format';
  import { handleLabel, readHandle } from '../lib/identity';
  import type { PanelAccount } from '../lib/types';
  import Avatar from './Avatar.svelte';
  import Chip from './Chip.svelte';
  import Plate from './Plate.svelte';

  const {
    accounts,
    viewerAccountId,
    onSetCanPair,
  }: {
    accounts: PanelAccount[];
    /** So the owner can tell their own row from everyone else's. */
    viewerAccountId: string;
    onSetCanPair: (accountId: string, granted: boolean) => Promise<void>;
  } = $props();

  let working = $state<string | null>(null);

  // A roster of people with one control each is a list, not a data table, and a
  // list reflows onto a phone without either scrolling sideways or dropping a
  // column that a decision depends on.
  const approved = $derived(accounts.filter((account) => account.can_pair).length);
  const now = Date.now();

  async function decide(account: PanelAccount): Promise<void> {
    working = account.id;
    try {
      await onSetCanPair(account.id, !account.can_pair);
    } finally {
      working = null;
    }
  }
</script>

<Plate label="Accounts">
  {#snippet status()}
    <span class="tally mono">{approved} of {accounts.length} approved</span>
  {/snippet}

  {#if accounts.length === 0}
    <p class="dim">Nobody has signed in yet</p>
  {:else}
    <ul class="roster">
      {#each accounts as account (account.id)}
        <li class="row">
          <Avatar {account} size={34} />
          <div class="who">
            <p class="name">
              {account.display_name}
              {#if account.id === viewerAccountId}
                <Chip small>You</Chip>
              {/if}
            </p>
            <!-- The state reads as the last fact about the account rather than as
                 a badge of its own. Four tinted blocks down the right-hand side
                 said no more than four words do, and the control beside each row
                 already names which state it is in. -->
            <!-- The relative time goes last because its width changes as it ages,
                 and anything after it would shift sideways on the tick. -->
            <p class="meta mono">
              {handleLabel(readHandle(account.provider, account.login))}
              ·
              <span class:approved={account.can_pair}>
                {account.can_pair ? 'approved' : 'awaiting approval'}
              </span>
              ·
              <span title={formatTimestamp(account.last_seen_at)}>
                seen {formatRelative(account.last_seen_at, now)}
              </span>
            </p>
          </div>
          <button
            class="btn decide"
            class:btn-stop={account.can_pair}
            disabled={working === account.id}
            onclick={() => decide(account)}
          >
            {account.can_pair ? 'Revoke' : 'Approve'}
          </button>
        </li>
      {/each}
    </ul>
    <p class="footnote dim">
      Revoking stops new links. One already generated stays claimable until it expires, and a device
      already paired keeps working. To cut a paired device off, run this on the daemon host:
      <code>harness-daemon remote clients revoke</code>
    </p>
  {/if}
</Plate>

<style>
  .tally {
    color: var(--dim);
    font-size: 0.6875rem;
    letter-spacing: 0.06em;
    text-transform: uppercase;
  }

  .roster {
    list-style: none;
    margin: 0;
    padding: 0;
  }

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
  .who {
    flex: 1 1 10rem;
    min-width: 0;
  }

  .name {
    align-items: center;
    display: flex;
    flex-wrap: wrap;
    font-weight: 600;
    gap: 0.4rem;
    margin: 0;
  }

  .meta {
    color: var(--dim);
    font-size: 0.6875rem;
    margin: 0.15rem 0 0;
    overflow-wrap: anywhere;
  }

  .approved {
    color: var(--clear);
  }

  .decide {
    flex: none;
    width: 5.75rem;
  }

  .footnote {
    border-top: 1px solid var(--rule);
    font-size: 0.8125rem;
    margin: 0;
    padding-top: 0.875rem;
  }
</style>
