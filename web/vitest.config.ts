import { defineConfig } from 'vitest/config';

// Next compiles JSX itself (tsconfig "jsx": "preserve"); component tests need the automatic runtime.
export default defineConfig({ esbuild: { jsx: 'automatic' } });
