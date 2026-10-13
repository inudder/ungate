import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
	FALLBACK_CODEX_CLIENT_VERSION,
	resetCodexClientVersionCache,
	resolveCodexClientVersion
} from 'src/services/codex-client-version';

const fetchMock = vi.fn<typeof fetch>();

function registryResponse(payload: unknown, status = 200): Response {
	return new Response(JSON.stringify(payload), { status });
}

describe('resolveCodexClientVersion', () => {
	beforeEach(() => {
		resetCodexClientVersionCache();
		vi.stubGlobal('fetch', fetchMock);
	});

	afterEach(() => {
		vi.useRealTimers();
		vi.unstubAllGlobals();
		vi.clearAllMocks();
		fetchMock.mockReset();
		delete process.env.CODEX_CLIENT_VERSION;
	});

	it('prefers the CODEX_CLIENT_VERSION override without calling npm', async () => {
		process.env.CODEX_CLIENT_VERSION = '1.2.3';

		await expect(resolveCodexClientVersion()).resolves.toBe('1.2.3');
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('uses the latest npm version and caches it', async () => {
		fetchMock.mockResolvedValue(registryResponse({ version: '0.170.0' }));

		await expect(resolveCodexClientVersion()).resolves.toBe('0.170.0');
		await expect(resolveCodexClientVersion()).resolves.toBe('0.170.0');
		expect(fetchMock).toHaveBeenCalledTimes(1);
	});

	it('falls back when npm is unreachable and retries after the backoff', async () => {
		vi.useFakeTimers();
		fetchMock.mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce(registryResponse({ version: '0.171.0' }));

		await expect(resolveCodexClientVersion()).resolves.toBe(FALLBACK_CODEX_CLIENT_VERSION);
		await expect(resolveCodexClientVersion()).resolves.toBe(FALLBACK_CODEX_CLIENT_VERSION);
		expect(fetchMock).toHaveBeenCalledTimes(1);

		vi.advanceTimersByTime(5 * 60 * 1000 + 1);
		await expect(resolveCodexClientVersion()).resolves.toBe('0.171.0');
	});

	it('rejects malformed versions', async () => {
		fetchMock.mockResolvedValue(registryResponse({ version: 'latest' }));

		await expect(resolveCodexClientVersion()).resolves.toBe(FALLBACK_CODEX_CLIENT_VERSION);
	});

	it('keeps the last good version when a refresh fails', async () => {
		vi.useFakeTimers();
		fetchMock.mockResolvedValueOnce(registryResponse({ version: '0.170.0' })).mockResolvedValueOnce(registryResponse({}, 500));

		await resolveCodexClientVersion();
		vi.advanceTimersByTime(12 * 60 * 60 * 1000 + 1);

		await expect(resolveCodexClientVersion()).resolves.toBe('0.170.0');
	});
});
