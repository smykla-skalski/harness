<script lang="ts">
  import { formatRelative, formatTimestamp } from '../lib/format';
  import { handleLabel, readHandle } from '../lib/identity';
  import type { PanelViewer } from '../lib/types';
  import Avatar from './Avatar.svelte';
  import Chip from './Chip.svelte';

  const {
    viewer,
    onSignOut,
  }: {
    /** `null` before the first load settles and whenever nobody is signed in. */
    viewer: PanelViewer | null;
    onSignOut: () => void;
  } = $props();

  const handle = $derived(
    viewer === null ? null : readHandle(viewer.account.provider, viewer.account.login),
  );
</script>

<header class="bar">
  <h1 class="mark">
    <span class="mark-name">Harness</span><span class="mark-rule" aria-hidden="true"></span><span
      class="mark-part">panel</span
    >
  </h1>

  {#if viewer !== null && handle !== null}
    <div class="who">
      <Avatar account={viewer.account} size={30} />
      <div class="who-text">
        <span class="who-name">{viewer.account.display_name}</span>
        <span class="who-handle mono">
          {handleLabel(handle)}
          <span class="who-joined" title={formatTimestamp(viewer.account.first_seen_at)}>
            · joined {formatRelative(viewer.account.first_seen_at, Date.now())}
          </span>
        </span>
      </div>
      {#if viewer.is_owner}
        <Chip tone="brass">Owner</Chip>
      {/if}
      <button class="btn btn-quiet" onclick={onSignOut}>Sign out</button>
    </div>
  {/if}
</header>

<style>
  .bar {
    align-items: center;
    display: flex;
    flex-wrap: wrap;
    gap: 0.75rem 1rem;
    justify-content: space-between;
    margin: 0 0 1.25rem;
    padding: 0 0.125rem;
  }

  /* Stamped-plate wordmark: the product, a hairline, the surface you are on. */
  .mark {
    align-items: center;
    display: flex;
    gap: 0.5rem;
    margin: 0;
  }

  .mark-name,
  .mark-part {
    font: 600 0.8125rem/1 var(--mono);
    letter-spacing: 0.22em;
    text-transform: uppercase;
  }

  .mark-part {
    color: var(--dim);
    font-weight: 500;
  }

  .mark-rule {
    background: var(--rule-strong);
    height: 1px;
    width: 0.625rem;
  }

  .who {
    align-items: center;
    display: flex;
    gap: 0.625rem;
  }

  .who-text {
    display: flex;
    flex-direction: column;
    gap: 0.15rem;
    min-width: 0;
  }

  .who-name {
    font-size: 0.875rem;
    font-weight: 600;
    line-height: 1.2;
  }

  .who-handle {
    color: var(--dim);
    font-size: 0.6875rem;
    line-height: 1.2;
  }

  /* On a phone the bar is already two lines. The join date is the one thing here
     nobody acts on, so it is what goes rather than anything identifying. */
  @media (max-width: 34rem) {
    .who-joined {
      display: none;
    }
  }
</style>
