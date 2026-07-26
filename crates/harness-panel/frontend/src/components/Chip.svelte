<script lang="ts">
  import type { Snippet } from 'svelte';

  /**
   * Tones name what a state means rather than which state it is, so the pairing
   * states arriving with the inventory view map onto these without new colours.
   */
  export type ChipTone = 'neutral' | 'good' | 'brass' | 'danger';

  const {
    tone = 'neutral',
    dot = false,
    children,
  }: {
    tone?: ChipTone;
    /** Set for a state that is live right now, rather than a fixed attribute. */
    dot?: boolean;
    children: Snippet;
  } = $props();
</script>

<span class="chip chip-{tone}">
  {#if dot}
    <span class="chip-dot"></span>
  {/if}
  {@render children()}
</span>
