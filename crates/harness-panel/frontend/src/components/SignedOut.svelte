<script lang="ts">
  const { href }: { href: string } = $props();
</script>

<section>
  <p>Sign in with GitHub to see your Harness panel account.</p>
  <a class="button" {href} rel="nofollow">Sign in with GitHub</a>
</section>
