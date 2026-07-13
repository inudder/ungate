import { afterEach, describe, expect, it, vi } from 'vitest';

import type { ModelMappingConfig } from '@ungate/shared';

const getAuthStatusMock = vi.fn();
const makeClaudeCodeRequestMock = vi.fn();
const proxyMiniMaxRequestMock = vi.fn();
const proxyOpenAIRequestMock = vi.fn();
const providerSettingsGetMock = vi.fn();
const openaiAuthStatusMock = vi.fn();

vi.mock('src/auth/oauth', () => ({
	OAuth: { getAuthStatus: () => getAuthStatusMock() }
}));

vi.mock('src/auth/openai', () => ({
	OpenAIOAuthService: { getAuthStatus: () => openaiAuthStatusMock() }
}));

vi.mock('src/database/provider-settings', () => ({
	ProviderSettings: { get: (...args: unknown[]) => providerSettingsGetMock(...args) }
}));

vi.mock('src/proxy/anthropic-client', () => ({
	makeClaudeCodeRequest: (...args: unknown[]) => makeClaudeCodeRequestMock(...args)
}));

vi.mock('src/proxy/minimax-client', () => ({
	proxyMiniMaxRequest: (...args: unknown[]) => proxyMiniMaxRequestMock(...args)
}));

vi.mock('src/proxy/proxy-client', () => ({
	proxyOpenAIRequest: (...args: unknown[]) => proxyOpenAIRequestMock(...args)
}));

import { ModelValidator } from 'src/services/model-validator';

function model(partial: Partial<ModelMappingConfig> & Pick<ModelMappingConfig, 'provider'>): ModelMappingConfig {
	return {
		id: partial.id ?? 'test-model',
		label: partial.label ?? 'Test Model',
		provider: partial.provider,
		upstreamModel: partial.upstreamModel ?? 'upstream-model',
		sortOrder: partial.sortOrder ?? 0,
		reasoningBudget: partial.reasoningBudget ?? null
	};
}

describe('ModelValidator', () => {
	afterEach(() => {
		vi.clearAllMocks();
	});

	it('rejects models without id or upstream', async () => {
		const result = await ModelValidator.validate(model({ provider: 'claude', id: '', upstreamModel: '' }));

		expect(result.ok).toBe(false);
		expect(result.available).toBe(false);
		expect(makeClaudeCodeRequestMock).not.toHaveBeenCalled();
	});

	it('returns not-logged-in for claude without auth without probing', async () => {
		getAuthStatusMock.mockReturnValue({ authenticated: false });

		const result = await ModelValidator.validate(model({ provider: 'claude' }));

		expect(result.available).toBe(false);
		expect(result.message).toContain('not logged in');
		expect(makeClaudeCodeRequestMock).not.toHaveBeenCalled();
	});

	it('marks claude available on successful probe', async () => {
		getAuthStatusMock.mockReturnValue({ authenticated: true });
		makeClaudeCodeRequestMock.mockResolvedValue({ success: true, response: new Response('{}', { status: 200 }) });

		const result = await ModelValidator.validate(model({ provider: 'claude', upstreamModel: 'claude-opus-4-8' }));

		expect(result.available).toBe(true);
		expect(result.statusCode).toBe(200);
	});

	it('surfaces claude upstream error message on 404', async () => {
		getAuthStatusMock.mockReturnValue({ authenticated: true });
		makeClaudeCodeRequestMock.mockResolvedValue({
			success: true,
			response: new Response(JSON.stringify({ error: { message: 'Claude Fable 5 is not available. Please use Opus 4.8.' } }), {
				status: 404
			})
		});

		const result = await ModelValidator.validate(model({ provider: 'claude', upstreamModel: 'claude-fable-5' }));

		expect(result.available).toBe(false);
		expect(result.statusCode).toBe(404);
		expect(result.message).toContain('Claude Fable 5 is not available');
	});

	it('surfaces claude failure result when request itself failed', async () => {
		getAuthStatusMock.mockReturnValue({ authenticated: true });
		makeClaudeCodeRequestMock.mockResolvedValue({ success: false, error: 'Rate limited', status: 429 });

		const result = await ModelValidator.validate(model({ provider: 'claude' }));

		expect(result.available).toBe(false);
		expect(result.statusCode).toBe(429);
		expect(result.message).toBe('Rate limited');
	});

	it('returns not-configured for minimax without api key', async () => {
		providerSettingsGetMock.mockReturnValue(null);

		const result = await ModelValidator.validate(model({ provider: 'minimax' }));

		expect(result.available).toBe(false);
		expect(result.message).toContain('not configured');
		expect(proxyMiniMaxRequestMock).not.toHaveBeenCalled();
	});

	it('marks minimax available on successful probe', async () => {
		providerSettingsGetMock.mockReturnValue({ accessToken: 'key' });
		proxyMiniMaxRequestMock.mockResolvedValue({ response: new Response('{}', { status: 200 }), context: {} });

		const result = await ModelValidator.validate(model({ provider: 'minimax' }));

		expect(result.available).toBe(true);
	});

	it('returns not-logged-in for openai without auth', async () => {
		openaiAuthStatusMock.mockReturnValue({ authenticated: false });

		const result = await ModelValidator.validate(model({ provider: 'openai' }));

		expect(result.available).toBe(false);
		expect(result.message).toContain('not logged in');
		expect(proxyOpenAIRequestMock).not.toHaveBeenCalled();
	});

	it('surfaces openai upstream error message', async () => {
		openaiAuthStatusMock.mockReturnValue({ authenticated: true });
		proxyOpenAIRequestMock.mockResolvedValue({
			response: new Response(JSON.stringify({ error: { message: 'model not found' } }), { status: 404 }),
			context: {}
		});

		const result = await ModelValidator.validate(model({ provider: 'openai' }));

		expect(result.available).toBe(false);
		expect(result.message).toBe('model not found');
	});
});
