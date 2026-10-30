import base from '@ungate/dev-kit/eslint';

export default [
	...base,
	{
		settings: {
			'import-x/internal-regex': '^(@ungate)(/|$)',
			'import-x/resolver': { typescript: { project: './tsconfig.json' } }
		},
		languageOptions: {
			parserOptions: {
				tsconfigRootDir: import.meta.dirname
			}
		}
	},
	{
		files: [
			'cliproxy-namespace-bridge*.mjs',
			'codex-model-shell-router*.mjs',
			'codex-model-capabilities*.mjs',
			'codex-output-limits*.mjs',
			'codex-memory-preflight*.mjs',
			'codex-tool*.mjs',
			'deepseek-responses*.mjs',
			'mimo-responses-namespace*.mjs',
			'mimo-responses-stream-adapter*.mjs',
			'ungate-patch-mcp*.mjs',
			'omniroute-context-limit.mjs',
			'omniroute-static-hooks.mjs'
		],
		rules: {
			'@typescript-eslint/no-floating-promises': 'off',
			'@typescript-eslint/await-thenable': 'off',
			'@typescript-eslint/prefer-nullish-coalescing': 'off',
			'@typescript-eslint/require-await': 'off',
			'@typescript-eslint/no-misused-promises': 'off',
			'@typescript-eslint/no-unsafe-argument': 'off',
			'@typescript-eslint/no-unsafe-assignment': 'off',
			'@typescript-eslint/no-unsafe-call': 'off',
			'@typescript-eslint/no-unsafe-member-access': 'off',
			'@typescript-eslint/no-unsafe-return': 'off',
			'import-x/no-unresolved': 'off',
			'vitest/no-disabled-tests': 'off',
			'vitest/no-import-node-test': 'off'
		}
	}
];
