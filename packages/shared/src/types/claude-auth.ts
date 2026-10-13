export type ClaudeAuthState = 'disconnected' | 'ready' | 'refreshing' | 'retry_wait' | 'reauth_required';

export interface ClaudeAuthStatus {
	authenticated: boolean;
	sessionExpired?: boolean;
	email?: string;
	state: ClaudeAuthState;
	expiresAt?: number;
	lastRefreshAt?: number;
	nextRetryAt?: number;
	errorCode?: string;
}
