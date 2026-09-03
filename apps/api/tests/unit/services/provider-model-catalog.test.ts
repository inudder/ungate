import { afterEach, describe, expect, it, vi } from 'vitest';

import { ProviderModelCatalog, ProviderModelCatalogError } from 'src/services/provider-model-catalog';

const mocks = vi.hoisted(() => ({
	claudeToken: vi.fn(),
	openaiToken: vi.fn(),
	providerSettingsGet: vi.fn()
}));

vi.mock('src/auth/oauth', () => ({ OAuth: { getValidToken: mocks.claudeToken } }));
vi.mock('src/auth/openai/openai-oauth-service', () => ({
	OpenAIOAuthService: { getValidToken: mocks.openaiToken }
}));
vi.mock('src/database/provider-settings', () => ({
	ProviderSettings: { get: mocks.providerSettingsGet }
}));

const fetchMock = vi.fn<typeof fetch>();

function jsonResponse(payload: unknown, status = 200): Response {
	return new Response(JSON.stringify(payload), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

describe('ProviderModelCatalog', () => {
	afterEach(() => {
		vi.unstubAllGlobals();
		vi.clearAllMocks();
		delete process.env.CODEX_CLIENT_VERSION;
	});

	it('loads and normalizes MiniMax models from a custom base URL', async () => {
		mocks.providerSettingsGet.mockReturnValue({ accessToken: 'minimax-secret', baseUrl: 'https://custom.minimax.test/' });
		fetchMock.mockResolvedValueOnce(
			jsonResponse({
				data: [
					{ id: ' MiniMax-M3 ', name: ' MiniMax M3 ' },
					{ id: 'minimax-m3', name: 'duplicate' },
					{ id: 'MiniMax-M2.7' },
					{ id: '  ' },
					{}
				]
			})
		);
		vi.stubGlobal('fetch', fetchMock);

		const result = await ProviderModelCatalog.list('minimax');

		expect(result).toEqual({
			provider: 'minimax',
			models: [
				{ upstreamModel: 'MiniMax-M3', label: 'MiniMax M3' },
				{ upstreamModel: 'MiniMax-M2.7', label: 'MiniMax-M2.7' }
			]
		});
		expect(fetchMock).toHaveBeenCalledWith(
			'https://custom.minimax.test/v1/models',
			expect.objectContaining({
				method: 'GET',
				headers: expect.objectContaining({ Authorization: 'Bearer minimax-secret' })
			})
		);
	});

	it('paginates the Claude catalog with Claude Code OAuth headers', async () => {
		mocks.claudeToken.mockResolvedValue({ accessToken: 'claude-secret' });
		fetchMock
			.mockResolvedValueOnce(
				jsonResponse({ data: [{ id: 'claude-a', display_name: 'Claude A' }], has_more: true, last_id: 'cursor-a' })
			)
			.mockResolvedValueOnce(
				jsonResponse({ data: [{ id: 'claude-b', display_name: 'Claude B' }], has_more: false, last_id: 'cursor-b' })
			);
		vi.stubGlobal('fetch', fetchMock);

		const result = await ProviderModelCatalog.list('claude');

		expect(result.models.map((model) => model.upstreamModel)).toEqual(['claude-a', 'claude-b']);
		expect(fetchMock).toHaveBeenCalledTimes(2);
		expect(fetchMock.mock.calls[0]?.[0]).toBe('https://api.anthropic.com/v1/models?limit=1000&beta=true');
		expect(fetchMock.mock.calls[1]?.[0]).toBe(
			'https://api.anthropic.com/v1/models?limit=1000&beta=true&after_id=cursor-a'
		);
		expect(fetchMock.mock.calls[0]?.[1]?.headers).toEqual(
			expect.objectContaining({
				Authorization: 'Bearer claude-secret',
				'anthropic-version': '2023-06-01',
				'x-app': 'cli'
			})
		);
	});

	it('filters OpenAI models by list visibility and sends Codex headers', async () => {
		process.env.CODEX_CLIENT_VERSION = '1.2.3';
		mocks.openaiToken.mockResolvedValue({ accessToken: 'openai-secret', accountId: 'account-1' });
		fetchMock.mockResolvedValueOnce(
			jsonResponse({
				models: [
					{ slug: 'gpt-visible', display_name: 'GPT Visible', visibility: 'list' },
					{ slug: 'gpt-hidden', display_name: 'GPT Hidden', visibility: 'hide' },
					{ slug: 'GPT-VISIBLE', display_name: 'duplicate', visibility: 'list' }
				]
			})
		);
		vi.stubGlobal('fetch', fetchMock);

		const result = await ProviderModelCatalog.list('openai');

		expect(result.models).toEqual([{ upstreamModel: 'gpt-visible', label: 'GPT Visible' }]);
		expect(fetchMock.mock.calls[0]?.[0]).toBe('https://chatgpt.com/backend-api/codex/models?client_version=1.2.3');
		expect(fetchMock.mock.calls[0]?.[1]?.headers).toEqual(
			expect.objectContaining({
				Authorization: 'Bearer openai-secret',
				'chatgpt-account-id': 'account-1',
				originator: 'codex_cli_rs'
			})
		);
	});

	it('uses a valid fallback OpenAI client version', async () => {
		mocks.openaiToken.mockResolvedValue({ accessToken: 'openai-secret', accountId: 'account-1' });
		fetchMock.mockResolvedValueOnce(jsonResponse({ models: [] }));
		vi.stubGlobal('fetch', fetchMock);

		await ProviderModelCatalog.list('openai');

		expect(fetchMock.mock.calls[0]?.[0]).toBe('https://chatgpt.com/backend-api/codex/models?client_version=0.0.0');
	});

	it.each(['claude', 'minimax', 'openai'] as const)('returns 401 when %s is not connected', async (provider) => {
		mocks.claudeToken.mockResolvedValue(null);
		mocks.openaiToken.mockResolvedValue(null);
		mocks.providerSettingsGet.mockReturnValue(null);

		await expect(ProviderModelCatalog.list(provider)).rejects.toMatchObject({ statusCode: 401 });
	});

	it('maps rejected upstream authorization to 401', async () => {
		mocks.providerSettingsGet.mockReturnValue({ accessToken: 'minimax-secret' });
		fetchMock.mockResolvedValueOnce(jsonResponse({ error: 'secret upstream details' }, 401));
		vi.stubGlobal('fetch', fetchMock);

		await expect(ProviderModelCatalog.list('minimax')).rejects.toMatchObject({ statusCode: 401 });
	});

	it('maps malformed JSON and malformed envelopes to 502', async () => {
		mocks.providerSettingsGet.mockReturnValue({ accessToken: 'minimax-secret' });
		fetchMock
			.mockResolvedValueOnce(new Response('{not-json', { status: 200 }))
			.mockResolvedValueOnce(jsonResponse({ data: 'not-an-array' }));
		vi.stubGlobal('fetch', fetchMock);

		await expect(ProviderModelCatalog.list('minimax')).rejects.toBeInstanceOf(ProviderModelCatalogError);
		await expect(ProviderModelCatalog.list('minimax')).rejects.toMatchObject({ statusCode: 502 });
	});

	it('accepts an empty provider catalog', async () => {
		mocks.providerSettingsGet.mockReturnValue({ accessToken: 'minimax-secret' });
		fetchMock.mockResolvedValueOnce(jsonResponse({ data: [] }));
		vi.stubGlobal('fetch', fetchMock);

		await expect(ProviderModelCatalog.list('minimax')).resolves.toEqual({ provider: 'minimax', models: [] });
	});

	it('maps request timeouts to 504', async () => {
		mocks.providerSettingsGet.mockReturnValue({ accessToken: 'minimax-secret' });
		fetchMock.mockRejectedValueOnce(Object.assign(new Error('timed out'), { name: 'TimeoutError' }));
		vi.stubGlobal('fetch', fetchMock);

		await expect(ProviderModelCatalog.list('minimax')).rejects.toMatchObject({ statusCode: 504 });
	});
});
