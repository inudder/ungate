import base from '@ungate/dev-kit/eslint';

export default [
	{
		ignores: ['bundle/**', 'scripts/smoke-browser.mjs', 'scripts/smoke-bundle.mjs']
	},
	...base,
	{
		settings: {
			'import-x/internal-regex': '^(@ungate|src)(/|$)',
			'import-x/resolver': { typescript: { project: './tsconfig.json' } }
		},
		languageOptions: {
			parserOptions: {
				tsconfigRootDir: import.meta.dirname
			}
		}
	}
];
