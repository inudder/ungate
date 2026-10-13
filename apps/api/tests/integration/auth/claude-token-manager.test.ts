import { afterEach, describe, expect, it, vi } from 'vitest';

import { ClaudeAuthError, ClaudeTokenManager } from 'src/auth/claude-token-manager';
import { OAuth } from 'src/auth/oauth';
import { ProviderSettings } from 'src/database/provider-settings';
import { closeClaudeTransport } from 'src/proxy/claude-transport';

function seed(expiresAt = Date.now() - 1000): void {
	ProviderSettings.upsertOAuth('claude', {
		accessToken: 'old-access',
		refreshToken: 'old-refresh',
		expiresAt,
		email: 'test@example.com',
		accountId: 'account'
	});
}

function refreshed(refreshToken: string | null = 'new-refresh'): Response {
	return Response.json({ access_token: 'new-access', refresh_token: refreshToken ?? undefined, expires_in: 3600 });
}

describe('Claude token retention', () => {
	afterEach(async () => {
		await ClaudeTokenManager.stop();
		await closeClaudeTransport();
		vi.useRealTimers();
		vi.unstubAllGlobals();
		vi.unstubAllEnvs();
	});

	it('shares one refresh and persists rotated credentials with account metadata', async () => {
		seed();
		let release!: (response: Response) => void;
		const fetcher = vi.fn(
			() =>
				new Promise<Response>((resolve) => {
					release = resolve;
				})
		);
		vi.stubGlobal('fetch', fetcher);
		const calls = Array.from({ length: 12 }, () => OAuth.getValidToken());
		expect(fetcher).toHaveBeenCalledTimes(1);
		release(refreshed());
		const results = await Promise.all(calls);
		expect(results.every((result) => result?.accessToken === 'new-access')).toBe(true);
		expect(ProviderSettings.get('claude')).toMatchObject({
			accessToken: 'new-access',
			refreshToken: 'new-refresh',
			email: 'test@example.com',
			accountId: 'account',
			authState: 'ready'
		});
	});

	it('reports refreshing promptly while the exchange is still in flight', async () => {
		seed();
		let release!: (response: Response) => void;
		vi.stubGlobal(
			'fetch',
			vi.fn(
				() =>
					new Promise<Response>((resolve) => {
						release = resolve;
					})
			)
		);
		const pending = ClaudeTokenManager.refresh();
		const status = await OAuth.checkAuthStatus();
		expect(status).toMatchObject({ state: 'refreshing', sessionExpired: false });
		release(refreshed());
		await pending;
		expect(OAuth.getAuthStatus()).toMatchObject({ state: 'ready', authenticated: true });
	});

	it('retains the old refresh token when rotation is omitted', async () => {
		seed();
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(refreshed(null)));
		await OAuth.getValidToken();
		expect(ProviderSettings.get('claude')?.refreshToken).toBe('old-refresh');
	});

	it.each([403, 429, 500])('keeps credentials and returns a temporary error for HTTP %s', async (status) => {
		seed();
		const fetcher = vi
			.fn()
			.mockResolvedValue(Response.json({ error: { type: 'forbidden', message: 'Request not allowed' } }, { status }));
		vi.stubGlobal('fetch', fetcher);
		await expect(OAuth.getValidToken()).rejects.toBeInstanceOf(ClaudeAuthError);
		expect(ProviderSettings.get('claude')).toMatchObject({
			accessToken: 'old-access',
			refreshToken: 'old-refresh',
			authState: 'retry_wait'
		});
		expect(OAuth.getAuthStatus()).toMatchObject({ authenticated: false, sessionExpired: false, state: 'retry_wait' });
		await expect(OAuth.getValidToken()).rejects.toMatchObject({ statusCode: 503 });
		expect(fetcher).toHaveBeenCalledTimes(1);
	});

	it('uses a still valid access token after a failed proactive refresh', async () => {
		seed(Date.now() + 60_000);
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(Response.json({}, { status: 503 })));
		const result1 = await OAuth.getValidToken();
		expect(result1?.accessToken).toBe('old-access');
		expect(OAuth.getAuthStatus()).toMatchObject({ authenticated: true, state: 'retry_wait', sessionExpired: false });
		await expect(OAuth.getValidToken('old-access')).rejects.toMatchObject({ statusCode: 503 });
	});

	it('honors Retry-After and persists retry state across a manager restart', async () => {
		vi.useFakeTimers();
		seed();
		const fetcher = vi
			.fn()
			.mockResolvedValueOnce(Response.json({}, { status: 429, headers: { 'Retry-After': '600' } }))
			.mockResolvedValue(refreshed());
		vi.stubGlobal('fetch', fetcher);
		await ClaudeTokenManager.maintain();
		expect(OAuth.getAuthStatus().nextRetryAt).toBe(Date.now() + 600_000);
		await ClaudeTokenManager.stop();
		ClaudeTokenManager.start();
		await vi.advanceTimersByTimeAsync(599_000);
		expect(fetcher).toHaveBeenCalledTimes(1);
		await vi.advanceTimersByTimeAsync(1000);
		expect(fetcher).toHaveBeenCalledTimes(2);
		expect(OAuth.getAuthStatus().state).toBe('ready');
	});

	it('persists 1, 5 and 15 minute backoff and refreshes after downtime', async () => {
		vi.useFakeTimers();
		seed();
		const fetcher = vi.fn().mockImplementation(() => Promise.resolve(Response.json({}, { status: 503 })));
		vi.stubGlobal('fetch', fetcher);
		for (const delay of [60_000, 300_000, 900_000, 900_000]) {
			await ClaudeTokenManager.maintain();
			expect(OAuth.getAuthStatus().nextRetryAt).toBe(Date.now() + delay);
			await vi.advanceTimersByTimeAsync(delay);
		}
		await ClaudeTokenManager.stop();
		vi.setSystemTime(Date.now() + 48 * 3_600_000);
		fetcher.mockImplementation(() => Promise.resolve(refreshed()));
		await ClaudeTokenManager.maintain();
		expect(OAuth.getAuthStatus()).toMatchObject({ authenticated: true, state: 'ready' });
		expect(ProviderSettings.get('claude')?.refreshFailures).toBe(0);
	});

	it('requires authorization for invalid_grant without erasing the evidence', async () => {
		seed();
		const fetcher = vi.fn().mockResolvedValue(Response.json({ error: 'invalid_grant' }, { status: 400 }));
		vi.stubGlobal('fetch', fetcher);
		const result2 = await OAuth.getValidToken();
		expect(result2).toBeNull();
		expect(OAuth.getAuthStatus()).toMatchObject({ state: 'reauth_required', errorCode: 'refresh_invalid', sessionExpired: true });
		expect(ProviderSettings.get('claude')?.refreshToken).toBe('old-refresh');
		await OAuth.refreshAuthStatus();
		expect(fetcher).toHaveBeenCalledTimes(1);
	});

	it('does not replay a refresh after an ambiguous timeout', async () => {
		seed();
		const fetcher = vi.fn().mockRejectedValue(new DOMException('Timed out', 'TimeoutError'));
		vi.stubGlobal('fetch', fetcher);
		const result3 = await OAuth.getValidToken();
		expect(result3).toBeNull();
		expect(OAuth.getAuthStatus()).toMatchObject({ state: 'reauth_required', errorCode: 'refresh_uncertain' });
		await ClaudeTokenManager.maintain();
		expect(fetcher).toHaveBeenCalledTimes(1);
		expect(ProviderSettings.get('claude')?.accessToken).toBe('old-access');
	});

	it('uses the unexpired access token after an uncertain refresh without replaying refresh', async () => {
		seed(Date.now() + 60_000);
		const fetcher = vi.fn().mockRejectedValue(new DOMException('Timed out', 'TimeoutError'));
		vi.stubGlobal('fetch', fetcher);
		const result4 = await OAuth.getValidToken();
		expect(result4?.accessToken).toBe('old-access');
		expect(OAuth.getAuthStatus()).toMatchObject({ state: 'reauth_required', errorCode: 'refresh_uncertain' });
		const result5 = await OAuth.getValidToken();
		expect(result5?.accessToken).toBe('old-access');
		const result6 = await OAuth.getValidToken('old-access');
		expect(result6).toBeNull();
		expect(fetcher).toHaveBeenCalledTimes(1);
	});

	it('treats an interrupted persisted refresh as uncertain after restart', async () => {
		seed();
		ProviderSettings.updateClaude(ProviderSettings.get('claude')!.credentialVersion, { authState: 'refreshing' });
		const fetcher = vi.fn();
		vi.stubGlobal('fetch', fetcher);
		await ClaudeTokenManager.maintain();
		expect(fetcher).not.toHaveBeenCalled();
		expect(OAuth.getAuthStatus().errorCode).toBe('refresh_uncertain');
	});

	it.each(['logout', 'login'] as const)('cannot overwrite a newer %s with an old refresh', async (action) => {
		seed();
		let release!: (response: Response) => void;
		vi.stubGlobal(
			'fetch',
			vi.fn(
				() =>
					new Promise<Response>((resolve) => {
						release = resolve;
					})
			)
		);
		const pending = OAuth.getValidToken();
		if (action === 'logout') OAuth.logout();
		else
			ProviderSettings.upsertOAuth('claude', {
				accessToken: 'login-access',
				refreshToken: 'login-refresh',
				expiresAt: Date.now() + 3_600_000
			});
		release(refreshed());
		await pending;
		const expectedAccess = action === 'logout' ? undefined : 'login-access';
		expect(ProviderSettings.get('claude')?.accessToken).toBe(expectedAccess);
	});

	it('cancels an in-flight login when the user logs out', async () => {
		let release!: (response: Response) => void;
		vi.stubGlobal(
			'fetch',
			vi.fn(
				() =>
					new Promise<Response>((resolve) => {
						release = resolve;
					})
			)
		);
		const session = await OAuth.startLogin();
		const pending = OAuth.completeLogin('code', session.sessionId);
		OAuth.logout();
		release(refreshed());
		const result7 = await pending;
		expect(result7.ok).toBe(false);
		expect(ProviderSettings.get('claude')).toBeUndefined();
	});

	it('refreshes automatically through 48 hours including overnight idle periods', async () => {
		vi.useFakeTimers();
		seed();
		let rotations = 0;
		const fetcher = vi.fn(() =>
			Promise.resolve(
				Response.json({ access_token: `access-${++rotations}`, refresh_token: `refresh-${rotations}`, expires_in: 3600 })
			)
		);
		vi.stubGlobal('fetch', fetcher);
		ClaudeTokenManager.start();
		await vi.advanceTimersByTimeAsync(48 * 3_600_000);
		expect(rotations).toBeGreaterThan(48);
		expect(OAuth.getAuthStatus()).toMatchObject({ authenticated: true, state: 'ready' });
		expect(fetcher.mock.calls.length > 48).toBe(true);
	});
});
