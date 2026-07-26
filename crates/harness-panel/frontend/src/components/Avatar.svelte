<script lang="ts">
  import { monogram } from '../lib/identity';
  import type { PanelAccount } from '../lib/types';

  const {
    account,
    size,
  }: {
    account: PanelAccount;
    size: number;
  } = $props();

  // A profile picture the browser cannot fetch leaves a broken-image glyph where
  // a face belongs, and the avatar host is one the panel does not control.
  let broken = $state(false);

  const source = $derived(broken ? null : account.avatar_url);
</script>

<!-- Decorative: the name it belongs to is always beside it, so announcing the
     picture as well would read the same account twice. The referrer is withheld
     because the avatar host has no business learning the panel's address. -->
{#if source !== null}
  <img
    class="avatar"
    style="--avatar-size: {size}px"
    src={source}
    alt=""
    width={size}
    height={size}
    loading="lazy"
    decoding="async"
    referrerpolicy="no-referrer"
    onerror={() => (broken = true)}
  />
{:else}
  <span class="avatar avatar-fallback" style="--avatar-size: {size}px" aria-hidden="true">
    {monogram(account.display_name, account.login)}
  </span>
{/if}
