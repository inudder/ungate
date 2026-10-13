import { afterEach, describe, expect, it, vi } from 'vitest';

import { OAuth } from 'src/auth/oauth';
import { config } from 'src/config';
import { ProviderSettings } from 'src/database/provider-settings';
import { makeClaudeCodeRequest } from 'src/proxy/anthropic-client';
import { ModelValidator } from 'src/services/model-validator';
import { ProviderModelCatalog } from 'src/services/provider-model-catalog';

const request = { model: 'claude-test', max_tokens: 16, messages: [{ role: 'user' as const, content: 'Hi' }] };
const model = {
	id: 'claude-test',
	label: 'Claude',
	provider: 'claude' as const,
	upstreamModel: 'claude-test',
	sortOrder: 0,
	reasoningBudget: null
};

describe('Claude consumers share refresh recovery', () => {
	afterEach(() => {
		vi.unstubAllGlobals();
	});

	it.each([503, 400])('returns the correct availability status after refresh HTTP %s', async (status) => {
		ProviderSettings.upsertOAuth('claude', { accessToken: 'old', refreshToken: 'refresh', expiresAt: Date.now() - 1000 });
		const fetcher = vi
			.fn()
			.mockImplementation(() =>
				Promise.resolve(Response.json({ error: status === 400 ? 'invalid_grant' : 'unavailable' }, { status }))
			);
		vi.stubGlobal('fetch', fetcher);
		const [inference, catalog, validation] = await Promise.all([
			makeClaudeCodeRequest('/v1/messages', request, {}),
			ProviderModelCatalog.list('claude').catch((error: unknown) => error),
			ModelValidator.validate(model)
		]);
		const expected = status === 400 ? 401 : 503;
		expect(inference).toMatchObject({ success: false, status: expected });
		expect(catalog).toMatchObject({ statusCode: expected });
		expect(validation).toMatchObject({ available: false, statusCode: expected });
		expect(fetcher).toHaveBeenCalledTimes(1);
		expect(ProviderSettings.get('claude')?.refreshToken).toBe('refresh');
	});

	it('shares one refresh across concurrent 401 inference and catalog responses', async () => {
		ProviderSettings.upsertOAuth('claude', { accessToken: 'old', refreshToken: 'refresh', expiresAt: Date.now() + 3_600_000 });
		let refreshes = 0;
		const fetcher = vi.fn((url: string, init?: RequestInit) => {
			if (url === config.claude.oauth.tokenUrl) {
				refreshes += 1;

				return Promise.resolve(Response.json({ access_token: 'new', refresh_token: 'rotated', expires_in: 3600 }));
			}
			if ((init?.headers as Record<string, string>).Authorization === 'Bearer old') {
				return Promise.resolve(Response.json({ error: 'expired' }, { status: 401 }));
			}

			return Promise.resolve(
				Response.json(url.includes('/v1/models') ? { data: [{ id: 'claude-test' }], has_more: false } : { content: [] })
			);
		});
		vi.stubGlobal('fetch', fetcher);
		const [inference, catalog] = await Promise.all([
			makeClaudeCodeRequest('/v1/messages', request, {}),
			ProviderModelCatalog.list('claude')
		]);
		expect(inference).toMatchObject({ success: true });
		expect(catalog.models).toHaveLength(1);
		expect(refreshes).toBe(1);
		expect(OAuth.getAuthStatus()).toMatchObject({ authenticated: true, state: 'ready' });
	});

	it('treats generic request rejection as temporary without expiring authorization', async () => {
		ProviderSettings.upsertOAuth('claude', { accessToken: 'old', refreshToken: 'refresh', expiresAt: Date.now() + 3_600_000 });
		vi.stubGlobal(
			'fetch',
			vi
				.fn()
				.mockImplementation(() => Promise.resolve(Response.json({ error: { message: 'Request not allowed' } }, { status: 403 })))
		);
		const result = await makeClaudeCodeRequest('/v1/messages', request, {});
		expect(result).toMatchObject({ success: false, status: 503 });
		await expect(ProviderModelCatalog.list('claude')).rejects.toMatchObject({ statusCode: 503 });
		expect(OAuth.getAuthStatus()).toMatchObject({ authenticated: true, state: 'ready', sessionExpired: false });
	});
});
