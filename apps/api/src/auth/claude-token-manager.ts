import { randomUUID } from 'node:crypto';

import { config } from '../config';
import { ProviderSettings } from '../database/provider-settings';
import { ClaudeTransportError, fetchClaude } from '../proxy/claude-transport';
import { logger } from '../utils/logger';

import type { AuthStatus, TokenInfo } from '../types';
import type { ClaudeAuthState } from '@ungate/shared';

type Credentials = NonNullable<ReturnType<typeof ProviderSettings.get>>;
const flights = new Map<string, Promise<TokenInfo | null>>();
const RETRY_DELAYS = [60_000, 300_000, 900_000];
let scheduler: NodeJS.Timeout | undefined;

export class ClaudeAuthError extends Error {
	readonly statusCode = 503;
	constructor(readonly code: string) {
		super('Claude authorization is temporarily unavailable. Retry later.');
		this.name = 'ClaudeAuthError';
	}
}

export function validatedTokenResponse(value: unknown): { accessToken: string; refreshToken?: string; expiresAt: number } {
	const data = value as { access_token?: unknown; refresh_token?: unknown; expires_in?: unknown } | null;
	if (
		!data ||
		typeof data.access_token !== 'string' ||
		!data.access_token.trim() ||
		typeof data.expires_in !== 'number' ||
		!Number.isFinite(data.expires_in) ||
		data.expires_in <= 0 ||
		(data.refresh_token !== undefined && (typeof data.refresh_token !== 'string' || !data.refresh_token.trim()))
	) {
		throw new Error('Invalid OAuth token response');
	}
	const expiresAt = Date.now() + data.expires_in * 1000;
	if (!Number.isSafeInteger(expiresAt)) throw new Error('Invalid OAuth expiry');

	return { accessToken: data.access_token, refreshToken: data.refresh_token, expiresAt };
}

function tokenFrom(row: Credentials | undefined): TokenInfo | null {
	if (!row?.accessToken || !row.expiresAt || row.expiresAt <= Date.now()) return null;
	if (row.authState === 'reauth_required' && row.authErrorCode !== 'refresh_uncertain') return null;

	return { accessToken: row.accessToken, refreshToken: row.refreshToken ?? '', expiresAt: row.expiresAt, isExpired: false };
}

function diagnostic(result: string, code?: string, status?: number): void {
	logger.log(
		`[claude-auth] ${new Date().toISOString()} result=${result}${code ? ` code=${code}` : ''}${status ? ` status=${status}` : ''}`
	);
}

function retryAfter(response: Response): number {
	const raw = response.headers.get('retry-after');
	if (!raw) return 0;
	const seconds = Number(raw);
	if (Number.isFinite(seconds)) return Math.max(0, seconds * 1000);
	const at = Date.parse(raw);

	return Number.isFinite(at) ? Math.max(0, at - Date.now()) : 0;
}

function recordFailure(row: Credentials, code: string, terminal: boolean, status?: number, minimumDelay = 0): void {
	const failures = row.refreshFailures + 1;
	const delay = Math.max(RETRY_DELAYS[Math.min(failures - 1, RETRY_DELAYS.length - 1)], minimumDelay);
	if (
		ProviderSettings.updateClaude(row.credentialVersion, {
			authState: terminal ? 'reauth_required' : 'retry_wait',
			authErrorCode: code,
			nextRetryAt: terminal ? null : Date.now() + delay,
			refreshFailures: failures
		})
	)
		diagnostic(terminal ? 'reauth_required' : 'retry_wait', code, status);
}

async function performRefresh(row: Credentials): Promise<TokenInfo | null> {
	if (!ProviderSettings.updateClaude(row.credentialVersion, { authState: 'refreshing', nextRetryAt: null }))
		return tokenFrom(ProviderSettings.get('claude'));
	diagnostic('refreshing');
	let response: Response;
	try {
		response = await fetchClaude(config.claude.oauth.tokenUrl, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			signal: AbortSignal.timeout(15_000),
			body: JSON.stringify({ grant_type: 'refresh_token', refresh_token: row.refreshToken, client_id: config.claude.clientId })
		});
	} catch (error) {
		const safe = error instanceof ClaudeTransportError && error.safeToRetry;
		recordFailure(row, safe ? error.code : 'refresh_uncertain', !safe);

		return null;
	}
	if (!response.ok) {
		const payload: unknown = await response.json().catch(() => null);
		const body = payload as { error?: string | { type?: string; code?: string } } | null;
		const error = typeof body?.error === 'string' ? body.error : (body?.error?.code ?? body?.error?.type);
		const terminal = error === 'invalid_grant' || error === 'invalid_refresh_token' || error === 'refresh_token_revoked';
		let code = 'upstream_error';
		if (terminal) code = 'refresh_invalid';
		else if (response.status === 403) code = 'upstream_forbidden';
		else if (response.status === 429) code = 'rate_limited';
		recordFailure(row, code, terminal, response.status, retryAfter(response));

		return null;
	}
	try {
		const payload: unknown = await response.json();
		const data = validatedTokenResponse(payload);
		const saved = ProviderSettings.updateClaude(row.credentialVersion, {
			...data,
			refreshToken: data.refreshToken ?? row.refreshToken,
			credentialVersion: randomUUID(),
			authState: 'ready',
			authErrorCode: null,
			lastRefreshAt: Date.now(),
			nextRetryAt: null,
			refreshFailures: 0
		});
		if (saved) diagnostic('ready', undefined, response.status);

		return tokenFrom(ProviderSettings.get('claude'));
	} catch {
		// A successful exchange may have rotated the token. Never replay the old pair.
		recordFailure(row, 'refresh_uncertain', true, response.status);

		return null;
	}
}

export class ClaudeTokenManager {
	static needsRefresh(expiresAt: number): boolean {
		return Date.now() >= expiresAt - 300_000;
	}

	static async refresh(force = false): Promise<TokenInfo | null> {
		const row = ProviderSettings.get('claude');
		if (!row || row.authState === 'reauth_required') return null;
		const pending = flights.get(row.credentialVersion);
		if (pending) return pending;
		if (row.authState === 'refreshing') {
			recordFailure(row, 'refresh_uncertain', true);

			return null;
		}
		if (!row.refreshToken) {
			recordFailure(row, 'missing_refresh_token', true);

			return null;
		}
		if (!force && row.nextRetryAt && row.nextRetryAt > Date.now()) return null;
		const promise = performRefresh(row).finally(() => flights.delete(row.credentialVersion));
		flights.set(row.credentialVersion, promise);

		return promise;
	}

	static async getValidToken(rejectedAccessToken?: string): Promise<TokenInfo | null> {
		let row = ProviderSettings.get('claude');
		if (!row) return null;
		let cached = tokenFrom(row);
		if (row.authState === 'reauth_required') {
			return cached && cached.accessToken !== rejectedAccessToken ? cached : null;
		}
		if (rejectedAccessToken && cached && cached.accessToken !== rejectedAccessToken) return cached;
		const rejected = rejectedAccessToken !== undefined;
		if (rejected || !cached || this.needsRefresh(row.expiresAt!) || row.authState === 'retry_wait') {
			await this.refresh(rejected && row.authState !== 'retry_wait');
			row = ProviderSettings.get('claude');
			cached = tokenFrom(row);
		}
		if (cached && (!rejected || cached.accessToken !== rejectedAccessToken)) return cached;
		if (!row || row.authState === 'reauth_required') return null;
		throw new ClaudeAuthError(row.authErrorCode ?? 'refresh_pending');
	}

	static getAuthStatus(): AuthStatus {
		const row = ProviderSettings.get('claude');
		if (!row) return { authenticated: false, state: 'disconnected' };
		let state = row.authState as ClaudeAuthState;
		if (!row.accessToken && !row.refreshToken) state = 'reauth_required';

		return {
			authenticated: state !== 'reauth_required' && !!tokenFrom(row),
			state,
			sessionExpired: state === 'reauth_required',
			email: row.email ?? undefined,
			expiresAt: row.expiresAt ?? undefined,
			lastRefreshAt: row.lastRefreshAt ?? undefined,
			nextRetryAt: row.nextRetryAt ?? undefined,
			errorCode: row.authErrorCode ?? undefined
		};
	}

	static async maintain(): Promise<void> {
		const row = ProviderSettings.get('claude');
		if (!row || row.authState === 'reauth_required') return;
		if (!row.accessToken || !row.expiresAt || this.needsRefresh(row.expiresAt) || row.authState !== 'ready') {
			await this.refresh();
		}
	}

	static start(): void {
		if (scheduler) return;
		const tick = () => void this.maintain().catch(() => diagnostic('maintenance_error', 'storage_error'));
		tick();
		scheduler = setInterval(tick, 60_000);
		scheduler.unref();
	}

	static async stop(): Promise<void> {
		clearInterval(scheduler);
		scheduler = undefined;
		await Promise.allSettled(flights.values());
	}
}
