export interface AuthStatus {
	authenticated: boolean;
	sessionExpired?: boolean;
	email?: string;
}

export interface LoginStart {
	authUrl: string;
	sessionId: string;
}
