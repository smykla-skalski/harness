import { svelte } from '@sveltejs/vite-plugin-svelte';
import { defineConfig } from 'vitest/config';

// The panel's mount point is a runtime flag (`--base-path`), but Vite bakes
// `base` into the emitted asset URLs at build time. Building against a sentinel
// and having the Rust asset handler substitute the configured prefix into
// `index.html` keeps one build correct under any mount point. Nothing outside
// `index.html` is rewritten, so the sentinel must not appear in the bundles.
export default defineConfig({
  base: '/__harness_panel_base__/',
  plugins: [svelte()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
  },
  test: {
    environment: 'node',
    include: ['tests/**/*.test.ts'],
  },
});
