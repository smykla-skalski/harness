<script lang="ts">
  import { formatTimestamp } from '../lib/format';
  import type { PanelViewer } from '../lib/types';

  const {
    viewer,
    onSignOut,
  }: {
    viewer: PanelViewer;
    onSignOut: () => void;
  } = $props();
</script>

<section>
  <h2>{viewer.account.display_name}</h2>
  <p class="muted">
    {viewer.account.provider}:{viewer.account.login}
    {#if viewer.is_owner}· panel owner{/if}
  </p>
  <p class="muted">First signed in {formatTimestamp(viewer.account.first_seen_at)}.</p>
  <button class="secondary" onclick={onSignOut}>Sign out</button>
</section>
