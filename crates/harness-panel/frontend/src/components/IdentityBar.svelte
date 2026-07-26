<script lang="ts">
  import { handleLabel, readHandle } from '../lib/identity';
  import type { PanelViewer } from '../lib/types';
  import Avatar from './Avatar.svelte';
  import Chip from './Chip.svelte';

  const {
    viewer,
    iconUrl,
    onSignOut,
  }: {
    /** `null` before the first load settles and whenever nobody is signed in. */
    viewer: PanelViewer | null;
    iconUrl: string;
    onSignOut: () => void;
  } = $props();

  const handle = $derived(
    viewer === null ? null : readHandle(viewer.account.provider, viewer.account.login),
  );
</script>

<header class="bar">
  <h1 class="mark">
    <img class="mark-icon" src={iconUrl} alt="" width="26" height="26" decoding="async" />
    <span class="mark-name">Harness</span>
    <span class="mark-part">panel</span>
  </h1>

  {#if viewer !== null && handle !== null}
    <div class="who">
      <Avatar account={viewer.account} size={30} />
      <div class="who-text">
        <p class="who-name">
          {viewer.account.display_name}
          {#if viewer.is_owner}
            <Chip tone="signal" small>Admin</Chip>
          {/if}
        </p>
        <span class="who-handle mono">{handleLabel(handle)}</span>
      </div>
      <button class="btn btn-quiet" onclick={onSignOut}>Sign out</button>
    </div>
  {/if}
</header>

<!-- The fan behind the tower in the app icon. The one ornament on the page, and
     the only thing tying it to the app it hands credentials to. -->
<div class="beam" aria-hidden="true"></div>

<style>
  .bar {
    align-items: center;
    display: flex;
    flex-wrap: wrap;
    gap: 0.75rem 1rem;
    justify-content: space-between;
    margin: 0 0 0.75rem;
    padding: 0 0.125rem;
  }

  .mark {
    align-items: center;
    display: flex;
    gap: 0.5rem;
    margin: 0;
  }

  .mark-icon {
    border-radius: 6px;
    flex: none;
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

  .beam {
    background: var(--beam);
    border-radius: 1px;
    height: 2px;
    margin-bottom: 1.25rem;
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
    align-items: center;
    display: flex;
    font-size: 0.875rem;
    font-weight: 600;
    gap: 0.375rem;
    line-height: 1.2;
    margin: 0;
  }

  .who-handle {
    color: var(--dim);
    font-size: 0.6875rem;
    line-height: 1.2;
  }
</style>
