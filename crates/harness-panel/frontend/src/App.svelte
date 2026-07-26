<script lang="ts">
  import AccountsRoster from './components/AccountsRoster.svelte';
  import IdentityBar from './components/IdentityBar.svelte';
  import PairLinkPanel from './components/PairLinkPanel.svelte';
  import Plate from './components/Plate.svelte';
  import SignedOut from './components/SignedOut.svelte';
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

<main class="shell">
  <IdentityBar {viewer} onSignOut={signOut} />

  {#if failure !== null}
    <Plate label="Problem" tone="alarm">
      <p>{failure}</p>
      <button class="btn" onclick={load}>Try again</button>
    </Plate>
  {/if}

  {#if loading}
    <Plate label="Panel">
      <p class="dim">Reading the panel…</p>
    </Plate>
  {:else if viewer !== null}
    <PairLinkPanel canPair={viewer.account.can_pair} onGenerate={api.createPairLink} />
    {#if viewer.is_owner}
      <AccountsRoster {accounts} viewerAccountId={viewer.account.id} onSetCanPair={setCanPair} />
    {/if}
    <!-- A failed load proves nothing about whether anyone is signed in, so the
       gate stays away: offering sign-in as the way out of a daemon outage sends
       someone to repeat what they have already done. -->
  {:else if failure === null}
    <SignedOut href={api.signInUrl()} />
  {/if}
</main>
