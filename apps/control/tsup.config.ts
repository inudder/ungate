import { defineConfig } from 'tsup';

export default defineConfig({
	entry: ['src/main.ts'],
	outDir: 'bundle',
	format: 'cjs',
	target: 'node22',
	bundle: true,
	splitting: false,
	sourcemap: false,
	clean: true,
	outExtension: () => ({ js: '.cjs' }),
	noExternal: [/.*/]
});
