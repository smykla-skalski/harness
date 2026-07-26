<script lang="ts">
  import AccountsTable from './components/AccountsTable.svelte';
  import SignedOut from './components/SignedOut.svelte';
  import ViewerCard from './components/ViewerCard.svelte';
  import type { PanelApi } from './lib/api';
  import type { PanelAccount, PanelViewer } from './lib/types';

  const { api }: { api: PanelApi } = $props();

  let loading = $state(true);
  let viewer = $state<PanelViewer | null>(null);
  let accounts = $state<PanelAccount[]>([]);
  let failure = $state<string | null>(null);

  async function load(): Promise<void> {
    loading = true;
    failure = null;
    try {
      viewer = await api.fetchViewer();
      // Only the owner may list accounts, so asking as anyone else would turn
      // an ordinary page load into a 403 the person cannot act on.
      accounts = viewer?.is_owner === true ? await api.fetchAccounts() : [];
    } catch (error) {
      failure = error instanceof Error ? error.message : String(error);
    } finally {
      loading = false;
    }
  }

  async function signOut(): Promise<void> {
    try {
      await api.signOut();
    } catch (error) {
      failure = error instanceof Error ? error.message : String(error);
      return;
    }
    viewer = null;
    accounts = [];
    await load();
  }

  void load();
</script>

<main>
  <h1>Harness panel</h1>

  {#if failure !== null}
    <section class="failure">
      <p>{failure}</p>
      <button class="secondary" onclick={load}>Try again</button>
    </section>
  {/if}

  {#if loading}
    <section><p class="muted">Loading…</p></section>
  {:else if viewer === null}
    <SignedOut href={api.signInUrl()} />
  {:else}
    <ViewerCard {viewer} onSignOut={signOut} />
    {#if viewer.is_owner}
      <AccountsTable {accounts} />
    {/if}
  {/if}
</main>
