<script lang="ts">
  import { formatTimestamp } from '../lib/format';
  import type { PanelAccount } from '../lib/types';

  const { accounts }: { accounts: PanelAccount[] } = $props();
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
          <th scope="col">First seen</th>
          <th scope="col">Last seen</th>
        </tr>
      </thead>
      <tbody>
        {#each accounts as account (account.id)}
          <tr>
            <td>
              {account.display_name}
              <span class="muted">({account.provider}:{account.login})</span>
            </td>
            <td>{formatTimestamp(account.first_seen_at)}</td>
            <td>{formatTimestamp(account.last_seen_at)}</td>
          </tr>
        {/each}
      </tbody>
    </table>
  {/if}
</section>
