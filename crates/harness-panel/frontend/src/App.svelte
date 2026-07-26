<script lang="ts">
  import AccountsRoster from './components/AccountsRoster.svelte';
  import IdentityBar from './components/IdentityBar.svelte';
  import PairingsTable from './components/PairingsTable.svelte';
  import PairLinkPanel from './components/PairLinkPanel.svelte';
  import Plate from './components/Plate.svelte';
  import SignedOut from './components/SignedOut.svelte';
  import type { PanelApi } from './lib/api';
  import type { PairLink, PanelAccount, PanelPairing, PanelViewer } from './lib/types';

  const { api, iconUrl }: { api: PanelApi; iconUrl: string } = $props();

  let loading = $state(true);
  let viewer = $state<PanelViewer | null>(null);
  let accounts = $state<PanelAccount[]>([]);
  let pairings = $state<PanelPairing[]>([]);
  let failure = $state<string | null>(null);
  /**
   * Kept apart from `failure`, because this one comes from the daemon rather
   * than from the panel. A daemon that cannot be reached should not make the
   * identity bar and the roster disappear behind a page-wide problem.
   */
  let pairingsFailure = $state<string | null>(null);

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
    if (viewer !== null) {
      await loadPairings();
    }
  }

  async function loadPairings(): Promise<void> {
    pairingsFailure = null;
    try {
      pairings = await api.fetchPairings();
    } catch (error) {
      pairingsFailure = error instanceof Error ? error.message : String(error);
    }
  }

  /**
   * Re-read rather than patch the row in place: the daemon is the authority on
   * what a pairing became, and one revoked elsewhere in the meantime should
   * settle at what it really is rather than at what this call did.
   */
  async function unpair(pairingId: string): Promise<void> {
    try {
      await api.revokePairing(pairingId);
    } catch (error) {
      pairingsFailure = error instanceof Error ? error.message : String(error);
      return;
    }
    await loadPairings();
  }

  /** Mint, then show the new link in the table without waiting for a reload. */
  async function generate(): Promise<PairLink> {
    const link = await api.createPairLink();
    void loadPairings();
    return link;
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
    pairingsFailure = null;
    viewer = null;
    accounts = [];
    pairings = [];
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
  <IdentityBar {viewer} {iconUrl} onSignOut={signOut} />

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
    <PairLinkPanel canPair={viewer.account.can_pair} onGenerate={generate} />
    <!-- Skipped only for someone who has nothing paired and cannot pair
         anything: for them the card above already says what to do, and an empty
         table underneath repeats it. A failure still shows the plate, because
         the alternative is swallowing it where nobody can see it. -->
    {#if pairings.length > 0 || viewer.account.can_pair || viewer.is_owner || pairingsFailure !== null}
      <PairingsTable
        {pairings}
        {accounts}
        showAccount={viewer.is_owner}
        failure={pairingsFailure}
        onUnpair={unpair}
      />
    {/if}
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
