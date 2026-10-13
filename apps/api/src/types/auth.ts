export type { ClaudeAuthStatus as AuthStatus } from '@ungate/shared';

export interface LoginStart {
	authUrl: string;
	sessionId: string;
}
