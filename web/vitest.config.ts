import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';
import { shepetalDomain } from './domain.config.mjs';

// Next compiles JSX itself (tsconfig "jsx"); component tests need the automatic runtime and the @/ alias.
export default defineConfig({
  esbuild: { jsx: 'automatic' },
  // the same SHEPETAL_DOMAIN as the build (wrangler.toml [vars])
  test: { env: { SHEPETAL_DOMAIN: shepetalDomain() } },
  resolve: { alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) } },
});
