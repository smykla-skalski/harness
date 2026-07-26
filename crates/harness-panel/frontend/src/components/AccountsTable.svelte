<script lang="ts">
  import { formatTimestamp } from '../lib/format';
  import type { PanelAccount } from '../lib/types';

  const {
    accounts,
    onSetCanPair,
  }: {
    accounts: PanelAccount[];
    onSetCanPair: (accountId: string, granted: boolean) => Promise<void>;
  } = $props();

  let working = $state<string | null>(null);

  async function decide(account: PanelAccount): Promise<void> {
    working = account.id;
    try {
      await onSetCanPair(account.id, !account.can_pair);
    } finally {
      working = null;
    }
  }
</script>

<section>
  <h2>Accounts</h2>
  {#if accounts.length === 0}
    <p class="muted">Nobody has signed in yet.</p>
  {:else}
    <table>
      <thead>
        <tr>
          <th scope="col">Account</th>
          <th scope="col">Can pair</th>
          <th scope="col">Last seen</th>
          <th scope="col"><span class="visually-hidden">Actions</span></th>
        </tr>
      </thead>
      <tbody>
        {#each accounts as account (account.id)}
          <tr>
            <td>
              {account.display_name}
              <span class="muted">({account.provider}:{account.login})</span>
            </td>
            <td>{account.can_pair ? 'Yes' : 'No'}</td>
            <td>{formatTimestamp(account.last_seen_at)}</td>
            <td>
              <button
                class="secondary"
                disabled={working === account.id}
                onclick={() => decide(account)}
              >
                {account.can_pair ? 'Revoke' : 'Approve'}
              </button>
            </td>
          </tr>
        {/each}
      </tbody>
    </table>
    <p class="muted">
      Revoking stops new links. A link already generated stays claimable until it expires, and a
      device already paired keeps working; cut one off with
      <code>harness-daemon remote clients revoke</code>.
    </p>
  {/if}
</section>

<style>
  .visually-hidden {
    clip-path: inset(50%);
    height: 1px;
    overflow: hidden;
    position: absolute;
    white-space: nowrap;
    width: 1px;
  }
</style>
