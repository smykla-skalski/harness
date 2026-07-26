<script lang="ts">
  import { formatTimestamp } from '../lib/format';
  import type { PairLink } from '../lib/types';

  const {
    canPair,
    onGenerate,
  }: {
    canPair: boolean;
    onGenerate: () => Promise<PairLink>;
  } = $props();

  let link = $state<PairLink | null>(null);
  let working = $state(false);
  let failure = $state<string | null>(null);

  async function generate(): Promise<void> {
    working = true;
    failure = null;
    try {
      link = await onGenerate();
    } catch (error) {
      failure = error instanceof Error ? error.message : String(error);
    } finally {
      working = false;
    }
  }
</script>

<section>
  <h2>Pair a device</h2>

  {#if !canPair}
    <p class="muted">The panel owner has not allowed this account to generate pairing links yet.</p>
  {:else if link === null}
    <p>
      Generating a link shows it once. Open it on the device you want to pair; it cannot be shown
      again afterwards.
    </p>
    <button onclick={generate} disabled={working}>
      {working ? 'Generating…' : 'Generate a pairing link'}
    </button>
  {:else}
    <p>
      Open this on the device you want to pair. It is shown once and expires
      {formatTimestamp(link.expires_at)}.
    </p>
    <!-- Selected on focus so it can be copied in one gesture, and readonly so
         an accidental edit cannot produce a link that looks right and is not.
         The value is a one-time code, so the browser is told to keep it out of
         form history and away from the spell checker, which in some browsers
         means a remote service. -->
    <input
      class="pair-link"
      type="text"
      readonly
      autocomplete="off"
      autocorrect="off"
      autocapitalize="off"
      spellcheck="false"
      value={link.pairing_url}
      aria-label="Pairing link"
      onfocus={(event) => event.currentTarget.select()}
    />
    <p class="muted">Grants the {link.role} role.</p>
    <!-- A link that lapsed before it was used has to be replaceable here. The
         alternative is a dead link and no control at all, recoverable only by
         reloading a page that says nothing about needing it. -->
    <button class="secondary" onclick={generate} disabled={working}>
      {working ? 'Generating…' : 'Generate another'}
    </button>
  {/if}

  {#if failure !== null}
    <p class="failure-text">{failure}</p>
  {/if}
</section>

<style>
  .pair-link {
    background: var(--panel-bg);
    border: 1px solid var(--panel-border);
    border-radius: 0.375rem;
    color: var(--panel-fg);
    font-family: ui-monospace, monospace;
    padding: 0.5rem;
    width: 100%;
  }

  .failure-text {
    color: #c8442f;
  }
</style>
