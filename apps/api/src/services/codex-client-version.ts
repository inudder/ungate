// The Codex catalog hides models whose minimum client version is above the one sent.
export const FALLBACK_CODEX_CLIENT_VERSION = '0.162.1';

const REGISTRY_URL = 'https://registry.npmjs.org/@openai/codex/latest';
const REGISTRY_TIMEOUT_MS = 3000;
const SUCCESS_TTL_MS = 12 * 60 * 60 * 1000;
const FAILURE_RETRY_MS = 5 * 60 * 1000;
const VERSION_PATTERN = /^\d+\.\d+\.\d+$/;

let cachedVersion: string | null = null;
let nextRefreshAt = 0;
let inflight: Promise<string> | null = null;

async function refresh(): Promise<string> {
	try {
		const response = await fetch(REGISTRY_URL, {
			headers: { Accept: 'application/json' },
			signal: AbortSignal.timeout(REGISTRY_TIMEOUT_MS)
		});
		if (!response.ok) throw new Error(`npm registry responded with ${response.status}`);

		const payload: unknown = await response.json();
		const version =
			typeof payload === 'object' && payload !== null && 'version' in payload && typeof payload.version === 'string'
				? payload.version.trim()
				: '';
		if (!VERSION_PATTERN.test(version)) throw new Error('npm registry returned an invalid version');

		cachedVersion = version;
		nextRefreshAt = Date.now() + SUCCESS_TTL_MS;
	} catch {
		nextRefreshAt = Date.now() + FAILURE_RETRY_MS;
	}

	return cachedVersion ?? FALLBACK_CODEX_CLIENT_VERSION;
}

/**
 * CODEX_CLIENT_VERSION wins; otherwise the latest @openai/codex release from npm
 * (cached), then the last known good value, then a built-in fallback.
 */
export async function resolveCodexClientVersion(): Promise<string> {
	const override = process.env.CODEX_CLIENT_VERSION?.trim();
	if (override) return override;

	if (Date.now() < nextRefreshAt) return cachedVersion ?? FALLBACK_CODEX_CLIENT_VERSION;

	inflight ??= refresh().finally(() => {
		inflight = null;
	});

	return inflight;
}

export function resetCodexClientVersionCache(): void {
	cachedVersion = null;
	nextRefreshAt = 0;
	inflight = null;
}
