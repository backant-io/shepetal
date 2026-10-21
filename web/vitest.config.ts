import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

// Next compiles JSX itself (tsconfig "jsx"); component tests need the automatic runtime and the @/ alias.
export default defineConfig({
  esbuild: { jsx: 'automatic' },
  resolve: { alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) } },
});
