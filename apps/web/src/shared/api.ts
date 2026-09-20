import { dashboardClient } from './dashboard-client';

import type {
	AnalyticsSummary,
	AppSettings,
	ModelMappingConfig,
	ModelMappingProvider,
	ModelValidationResult,
	Period,
	PromptCacheAnalytics,
	RequestRecord,
	TokenSeriesPoint,
	ProviderModelsResponse
} from '@ungate/shared/frontend';

export interface WakePingStatus {
	enabled: boolean;
	workStart: string;
	workEnd: string;
	nextPingAt: string | null;
	lastPingAt: string | null;
	lastPingError: string | null;
	running: boolean;
}

export class Api {
	private static get<T>(path: string): Promise<T> {
		return dashboardClient.backend(path);
	}

	private static post<T>(path: string, body?: unknown): Promise<T> {
		return dashboardClient.backend(path, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(body ?? {})
		});
	}

	static fetchAnalytics(period: Period): Promise<AnalyticsSummary> {
		return this.get(`/analytics?period=${period}`);
	}

	static fetchRequests(limit: number): Promise<{ requests: RequestRecord[] }> {
		return this.get(`/analytics/requests?limit=${limit}`);
	}

	static fetchTokenSeries(period: Period): Promise<{ period: Period; series: TokenSeriesPoint[] }> {
		return this.get(`/analytics/tokens?period=${period}`);
	}

	static fetchPromptCacheAnalytics(period: Period): Promise<PromptCacheAnalytics> {
		return this.get(`/analytics/cache?period=${period}`);
	}

	static resetAnalytics(): Promise<{ success: boolean; deletedCount: number }> {
		return this.post('/analytics/reset');
	}

	static fetchSettings(): Promise<AppSettings> {
		return this.get('/settings');
	}

	static updateSettings(settings: Partial<AppSettings>): Promise<{ ok: boolean }> {
		return this.post('/settings', settings);
	}

	static validateModel(model: ModelMappingConfig): Promise<ModelValidationResult> {
		return this.post('/models/validate', { model });
	}

	static fetchAvailableModels(provider: ModelMappingProvider): Promise<ProviderModelsResponse> {
		return this.get(`/models/available/${encodeURIComponent(provider)}`);
	}

	static authStart(): Promise<{ authUrl: string; sessionId: string }> {
		return this.post('/auth/claude/start');
	}

	static authComplete(code: string, sessionId: string): Promise<{ ok: boolean; email?: string; error?: string }> {
		return this.post('/auth/claude/complete', { code, sessionId });
	}

	static authStatus(): Promise<{ authenticated: boolean; sessionExpired?: boolean; email?: string }> {
		return this.get('/auth/claude/status');
	}

	static authLogout(): Promise<{ ok: boolean }> {
		return this.post('/auth/claude/logout');
	}

	static authMinimaxStatus(): Promise<{ authenticated: boolean; baseUrl?: string }> {
		return this.get('/auth/minimax/status');
	}

	static authMinimaxLogin(apiKey: string, baseUrl: string): Promise<{ ok: boolean; error?: string }> {
		return this.post('/auth/minimax/login', { apiKey, baseUrl });
	}

	static authMinimaxUpdateBaseUrl(baseUrl: string): Promise<{ ok: boolean; error?: string }> {
		return this.post('/auth/minimax/base-url', { baseUrl });
	}

	static authMinimaxLogout(): Promise<{ ok: boolean }> {
		return this.post('/auth/minimax/logout');
	}

	static authChatGPTStart(): Promise<{ authUrl: string; sessionId: string }> {
		return this.get('/auth/openai/start');
	}

	static authChatGPTStatus(): Promise<{ authenticated: boolean; email?: string }> {
		return this.get('/auth/openai/status');
	}

	static authChatGPTLogout(): Promise<{ ok: boolean }> {
		return this.post('/auth/openai/logout');
	}

	static wakePingStatus(): Promise<WakePingStatus> {
		return this.get('/wake-ping');
	}

	static updateWakePing(update: Partial<Pick<WakePingStatus, 'enabled' | 'workStart' | 'workEnd'>>): Promise<{ ok: boolean }> {
		return this.post('/wake-ping', update);
	}

	static sendWakePing(): Promise<{ ok: boolean; lastPingAt: string | null; lastPingError: string | null }> {
		return this.post('/wake-ping/ping');
	}

	static async healthCheck(): Promise<boolean> {
		try {
			const response = await dashboardClient.backend<{ status: string }>('/health');

			return response.status === 'ok';
		} catch {
			return false;
		}
	}
}
