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
			'codex-tool*.mjs',
			'deepseek-responses*.mjs',
			'mimo-responses-namespace*.mjs',
			'mimo-responses-stream-adapter*.mjs',
			'ungate-patch-mcp*.mjs'
		],
		rules: {
			'@typescript-eslint/no-floating-promises': 'off',
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
