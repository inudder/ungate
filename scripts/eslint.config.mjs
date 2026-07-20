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
		files: ['cliproxy-namespace-bridge*.mjs'],
		rules: {
			'@typescript-eslint/no-floating-promises': 'off',
			'@typescript-eslint/no-misused-promises': 'off',
			'@typescript-eslint/no-unsafe-argument': 'off',
			'@typescript-eslint/no-unsafe-assignment': 'off',
			'@typescript-eslint/no-unsafe-call': 'off',
			'@typescript-eslint/no-unsafe-member-access': 'off',
			'@typescript-eslint/no-unsafe-return': 'off',
			'vitest/no-import-node-test': 'off'
		}
	}
];
