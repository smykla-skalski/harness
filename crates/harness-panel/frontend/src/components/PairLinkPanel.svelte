<script lang="ts">
  import type { ClipboardWriter } from '../lib/clipboard';
  import { copyText } from '../lib/clipboard';
  import { formatCountdown, formatTimestamp, remainingFraction, remainingMs } from '../lib/format';
  import type { PairLink } from '../lib/types';
  import Chip from './Chip.svelte';
  import Plate from './Plate.svelte';

  const {
    canPair,
    onGenerate,
  }: {
    canPair: boolean;
    onGenerate: () => Promise<PairLink>;
  } = $props();

  /** Close enough to lapsing that the countdown should say so in colour too. */
  const URGENT_MS = 5 * 60 * 1_000;
  const COPIED_SETTLE_MS = 2_500;
  const TICK_MS = 1_000;

  let link = $state<PairLink | null>(null);
  /**
   * When the link arrived. The reply carries a deadline but no start, and the
   * drain track has to measure the remainder against a whole lifetime.
   */
  let issuedMs = $state(0);
  let nowMs = $state(0);
  let working = $state(false);
  let failure = $state<string | null>(null);
  let copyState = $state<'idle' | 'copied' | 'manual'>('idle');
  let field = $state<HTMLInputElement | null>(null);

  const leftMs = $derived(link === null ? null : remainingMs(link.expires_at, nowMs));
  const expired = $derived(leftMs === 0);
  const urgent = $derived(leftMs !== null && leftMs > 0 && leftMs <= URGENT_MS);
  const left = $derived.by(() => {
    if (link === null || leftMs === null) {
      return 0;
    }
    return remainingFraction(issuedMs, Date.parse(link.expires_at), nowMs);
  });

  const copyNote = $derived.by(() => {
    switch (copyState) {
      case 'copied':
        return 'Copied to the clipboard.';
      case 'manual':
        return 'This browser would not let the page copy. The link is selected; press Cmd-C or Ctrl-C.';
      case 'idle':
        return '';
    }
  });

  // Depends on the link alone. Reading the countdown here instead would tear the
  // interval down and rebuild it on every tick.
  $effect(() => {
    const current = link;
    if (current === null) {
      return;
    }
    const deadline = Date.parse(current.expires_at);
    nowMs = Date.now();
    const tick = setInterval(() => {
      nowMs = Date.now();
      if (Number.isFinite(deadline) && nowMs >= deadline) {
        clearInterval(tick);
      }
    }, TICK_MS);
    return () => {
      clearInterval(tick);
    };
  });

  $effect(() => {
    if (copyState !== 'copied') {
      return;
    }
    const settle = setTimeout(() => {
      copyState = 'idle';
    }, COPIED_SETTLE_MS);
    return () => {
      clearTimeout(settle);
    };
  });

  async function generate(): Promise<void> {
    working = true;
    failure = null;
    copyState = 'idle';
    try {
      const minted = await onGenerate();
      issuedMs = Date.now();
      nowMs = issuedMs;
      link = minted;
    } catch (error) {
      failure = error instanceof Error ? error.message : String(error);
    } finally {
      working = false;
    }
  }

  async function copy(): Promise<void> {
    if (link === null) {
      return;
    }
    const writer: ClipboardWriter | undefined = navigator.clipboard;
    if ((await copyText(link.pairing_url, writer)) === 'copied') {
      copyState = 'copied';
      return;
    }
    // Nothing else can reach the clipboard, so hand over the selection and let
    // the person finish it themselves.
    copyState = 'manual';
    field?.focus();
    field?.select();
  }
</script>

<Plate label="Pair a device" tone="lead">
  {#snippet status()}
    {#if !canPair}
      <Chip>Not allowed</Chip>
    {:else if link === null}
      <Chip tone="good" dot>Can pair</Chip>
    {:else if expired}
      <Chip tone="danger">Expired</Chip>
    {:else}
      <Chip tone="brass" dot>Link live</Chip>
    {/if}
  {/snippet}

  {#if !canPair}
    <p class="dim">
      Ask the panel owner to approve this account. Once they have, you can generate a link here.
    </p>
  {:else if link === null}
    <p>A link is shown once and cannot be shown again. Open it on the device you want to pair.</p>
    <button class="btn btn-brass" onclick={generate} disabled={working}>
      {working ? 'Generating…' : 'Generate a pairing link'}
    </button>
  {:else}
    {#if !expired}
      <p>Open this on the device you want to pair. It is not shown again.</p>
    {/if}
    <div class="ticket" class:ticket-spent={expired}>
      <!-- Selected on focus so it can be copied in one gesture even where the
           clipboard is refused, and readonly so an accidental edit cannot produce
           a link that looks right and is not. The value is a one-time code, so the
           browser is told to keep it out of form history and away from the spell
           checker, which in some browsers means a remote service. -->
      <div class="well">
        <input
          bind:this={field}
          class="value mono"
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
        <button class="btn copy" onclick={copy} disabled={expired}>
          {copyState === 'copied' ? 'Copied' : 'Copy'}
        </button>
      </div>

      {#if leftMs !== null}
        <div class="track" aria-hidden="true">
          <div class="fill" class:fill-urgent={urgent} style="width: {left * 100}%"></div>
        </div>
      {/if}

      <p class="meta mono">
        <span class="role">{link.role}</span>
        <span aria-hidden="true">·</span>
        <!-- Ticking text in a live region would be read out every second, so the
             number is shown and the deadline itself is announced instead. -->
        {#if leftMs === null}
          <span>expiry unknown</span>
        {:else if expired}
          <span class="gone">expired</span>
        {:else}
          <span class="count" class:count-urgent={urgent} aria-hidden="true">
            expires in {formatCountdown(leftMs)}
          </span>
        {/if}
        <span class="visually-hidden">
          expires <time datetime={link.expires_at}>{formatTimestamp(link.expires_at)}</time>
        </span>
      </p>
    </div>

    <p class="note" class:note-quiet={copyState !== 'manual'} role="status">{copyNote}</p>

    {#if expired}
      <p>This link lapsed before anything claimed it. Generate another to pair the device.</p>
    {/if}
    <button class="btn" class:btn-brass={expired} onclick={generate} disabled={working}>
      {working ? 'Generating…' : 'Generate another'}
    </button>
  {/if}

  {#if failure !== null}
    <p class="failure">{failure}</p>
  {/if}
</Plate>

<style>
  .ticket {
    margin-bottom: 1rem;
  }

  /* The brass edge is the cut side of the key: the one part of the page that
     holds a live credential. */
  .well {
    align-items: center;
    background: var(--well);
    border: 1px solid var(--brass-edge);
    border-left: 3px solid var(--brass);
    border-radius: var(--r-ctl);
    display: flex;
    gap: 0.5rem;
    padding: 0.375rem 0.375rem 0.375rem 0.75rem;
  }

  .value {
    background: transparent;
    border: 0;
    color: var(--text);
    flex: 1;
    font-size: 0.8125rem;
    min-width: 0;
    padding: 0.25rem 0;
  }

  .value:focus {
    outline: none;
  }

  .copy {
    background: var(--plate);
    flex: none;
    min-height: 1.875rem;
    padding: 0 0.75rem;
  }

  /* Draining as the lifetime burns down, because the only thing worth knowing
     about a one-time link is how much of it is left. */
  .track {
    background: var(--rule);
    border-radius: 999px;
    height: 2px;
    margin: 0.75rem 0 0.5rem;
    overflow: hidden;
  }

  .fill {
    background: var(--brass);
    height: 100%;
    transition: width 1s linear;
  }

  .fill-urgent {
    background: var(--clay);
  }

  @media (prefers-reduced-motion: reduce) {
    .fill {
      transition: none;
    }
  }

  .meta {
    align-items: center;
    color: var(--dim);
    display: flex;
    flex-wrap: wrap;
    font-size: 0.6875rem;
    gap: 0.4rem;
    letter-spacing: 0.04em;
    margin: 0;
    text-transform: uppercase;
  }

  .role {
    color: var(--text);
    font-weight: 600;
  }

  /* The one number on the page that changes while it is being read. */
  .count {
    font-size: 0.75rem;
  }

  .count-urgent,
  .gone {
    color: var(--clay);
    font-weight: 600;
  }

  .ticket-spent .well {
    border-color: var(--rule);
    border-left-color: var(--rule-strong);
  }

  .ticket-spent .value {
    color: var(--dim);
  }

  /* Only the manual-copy instruction is ever visible here, so this reads as
     direction rather than as the confirmation the button already gives. */
  .note {
    font-size: 0.8125rem;
    margin: 0 0 0.875rem;
  }

  /* Kept in the accessibility tree for the confirmation the button already shows
     visually, so it is announced once without repeating what is on screen. */
  .note-quiet {
    clip-path: inset(50%);
    height: 1px;
    overflow: hidden;
    position: absolute;
    white-space: nowrap;
    width: 1px;
  }

  .failure {
    color: var(--clay);
    margin: 0.875rem 0 0;
  }
</style>
