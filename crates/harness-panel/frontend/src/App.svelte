<script lang="ts">
  import AccountsTable from './components/AccountsTable.svelte';
  import PairLinkPanel from './components/PairLinkPanel.svelte';
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
    // Only the first load blanks the page. A later refresh keeps what is on
    // screen, because tearing the tree down would destroy the shown-once
    // pairing link that nothing else holds a copy of.
    loading = viewer === null;
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

  async function setCanPair(accountId: string, granted: boolean): Promise<void> {
    try {
      await api.setCanPair(accountId, granted);
      // Re-read rather than patching in place: the decision may have changed
      // the viewer's own row, and the server is the authority on both. `load`
      // leaves the page standing, so a link already on screen survives.
      await load();
    } catch (error) {
      failure = error instanceof Error ? error.message : String(error);
    }
  }

  async function signOut(): Promise<void> {
    loading = true;
    failure = null;
    viewer = null;
    accounts = [];
    try {
      await api.signOut();
    } catch (error) {
      const signOutFailure = error instanceof Error ? error.message : String(error);
      await load();
      failure = signOutFailure;
      return;
    }
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
    <PairLinkPanel canPair={viewer.account.can_pair} onGenerate={api.createPairLink} />
    {#if viewer.is_owner}
      <AccountsTable {accounts} onSetCanPair={setCanPair} />
    {/if}
  {/if}
</main>
