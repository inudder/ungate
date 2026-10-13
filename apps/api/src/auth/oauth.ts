import { randomBytes } from 'node:crypto';

import { minutesToMilliseconds } from 'date-fns';

import { logger } from 'src/utils/logger';

import { config } from '../config';
import { ProviderSettings } from '../database/provider-settings';
import { fetchClaude } from '../proxy/claude-transport';

import { ClaudeTokenManager, validatedTokenResponse } from './claude-token-manager';

import type { TokenInfo, TokenRefreshResponse, AuthStatus, LoginStart } from '../types/index';

interface PkceSession {
	codeVerifier: string;
	expiresAt: number;
	epoch: number;
}

interface TokenExchangeResponse extends TokenRefreshResponse {
	account?: { uuid: string; email_address: string };
}

export class OAuth {
	private static epoch = 0;
	private static readonly pkceStore = new Map<string, PkceSession>();
	private static readonly SESSION_TTL_MS = minutesToMilliseconds(15);

	static {
		setInterval(() => {
			const now = Date.now();

			for (const [sessionId, session] of this.pkceStore) {
				if (now >= session.expiresAt) {
					this.pkceStore.delete(sessionId);
				}
			}
		}, minutesToMilliseconds(1)).unref();
	}

	private static base64urlEncode(buf: Buffer): string {
		return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
	}

	private static async generatePkce(): Promise<{ verifier: string; challenge: string }> {
		const verifier = this.base64urlEncode(randomBytes(32));
		const enc = new TextEncoder();
		const digest = await crypto.subtle.digest('SHA-256', enc.encode(verifier));
		const challenge = this.base64urlEncode(Buffer.from(digest));

		return { verifier, challenge };
	}

	static async startLogin(): Promise<LoginStart> {
		const epoch = ++this.epoch;
		this.pkceStore.clear();
		const { verifier, challenge } = await this.generatePkce();
		const sessionId = verifier;

		this.pkceStore.set(sessionId, {
			codeVerifier: verifier,
			expiresAt: Date.now() + this.SESSION_TTL_MS,
			epoch
		});

		const params = new URLSearchParams({
			code: 'true',
			response_type: 'code',
			client_id: config.claude.clientId,
			redirect_uri: config.claude.oauth.redirectUri,
			scope: 'org:create_api_key user:profile user:inference',
			code_challenge: challenge,
			code_challenge_method: 'S256',
			state: verifier
		});

		const result: LoginStart = {
			authUrl: `https://claude.ai/oauth/authorize?${params}`,
			sessionId
		};

		return result;
	}

	static async completeLogin(codeInput: string, sessionId: string): Promise<{ ok: boolean; email?: string; error?: string }> {
		const session = this.pkceStore.get(sessionId);

		if (!session) {
			return { ok: false, error: 'Session not found or expired' };
		}

		if (Date.now() >= session.expiresAt) {
			this.pkceStore.delete(sessionId);

			return { ok: false, error: 'Session expired' };
		}

		this.pkceStore.delete(sessionId);

		// Input may be CODE#STATE — split to extract both
		const parts = codeInput.trim().split('#');
		const code = parts[0];
		const state = parts[1] ?? sessionId;

		try {
			const response = await fetchClaude(config.claude.oauth.tokenUrl, {
				signal: AbortSignal.timeout(15_000),
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({
					grant_type: 'authorization_code',
					client_id: config.claude.clientId,
					redirect_uri: config.claude.oauth.redirectUri,
					code,
					state,
					code_verifier: session.codeVerifier
				})
			});

			if (!response.ok) {
				await response.body?.cancel();
				logger.error(`[claude-auth] ${new Date().toISOString()} result=exchange_failed status=${response.status}`);

				return { ok: false, error: `Token exchange failed: ${response.status}` };
			}

			const data: TokenExchangeResponse = await response.json();
			const credentials = validatedTokenResponse(data);
			if (!credentials.refreshToken) throw new Error('Missing OAuth refresh token');
			if (session.epoch !== this.epoch) return { ok: false, error: 'Login superseded or cancelled' };
			const email = data.account?.email_address;

			ProviderSettings.upsertOAuth('claude', {
				...credentials,
				email,
				accountId: data.account?.uuid
			});

			logger.log('✓ OAuth login complete', email ? `(${email})` : '');

			return { ok: true, email };
		} catch {
			logger.error(`[claude-auth] ${new Date().toISOString()} result=exchange_error`);

			return { ok: false, error: 'Unable to complete Claude login. Check the Claude proxy connection and try again.' };
		}
	}

	static isTokenExpired(expiresAt: number): boolean {
		return ClaudeTokenManager.needsRefresh(expiresAt);
	}

	static refreshToken(_refreshTokenValue?: string): Promise<TokenInfo | null> {
		return ClaudeTokenManager.refresh(true);
	}

	static getValidToken(rejectedAccessToken?: string): Promise<TokenInfo | null> {
		return ClaudeTokenManager.getValidToken(rejectedAccessToken);
	}

	static clearCachedToken(): void {}

	static markExpired(): void {
		ProviderSettings.markExpired('claude');
	}

	static getAuthStatus(): AuthStatus {
		return ClaudeTokenManager.getAuthStatus();
	}

	static checkAuthStatus(): Promise<AuthStatus> {
		void ClaudeTokenManager.maintain().catch(() => {
			logger.error(`[claude-auth] ${new Date().toISOString()} result=maintenance_error code=storage_error`);
		});

		return Promise.resolve(this.getAuthStatus());
	}

	static async refreshAuthStatus(): Promise<AuthStatus> {
		await ClaudeTokenManager.refresh(true);

		return this.getAuthStatus();
	}

	static logout(): void {
		this.epoch += 1;
		this.pkceStore.clear();
		ProviderSettings.remove('claude');
		logger.log('✓ Logged out, OAuth tokens deleted');
	}
}
