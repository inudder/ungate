export type Period = 'hour' | 'day' | 'week' | 'month' | 'all';

export type RequestSource = 'claude' | 'minimax' | 'openai' | 'error';

export interface AnalyticsSummary {
	totalRequests: number;
	claudeRequests: number;
	minimaxRequests: number;
	openaiRequests: number;
	errorRequests: number;
	totalInputTokens: number;
	totalOutputTokens: number;
	periodStart: number;
	periodEnd: number;
	period?: Period;
	note?: string;
}

export interface RequestRecord {
	id?: number;
	timestamp?: number;
	model: string;
	source: RequestSource;
	inputTokens: number;
	outputTokens: number;
	cacheReadTokens?: number;
	cacheCreationTokens?: number;
	estimatedCost?: number;
	stream: boolean;
	latencyMs: number | null;
	error?: string | null;
}

export interface PromptCacheModelStats {
	model: string;
	requests: number;
	cacheHitRequests: number;
	cacheWriteRequests: number;
	inputTokens: number;
	cacheReadTokens: number;
	cacheCreationTokens: number;
	reuseRate: number;
}

export interface PromptCacheAnalytics {
	period: Period;
	periodStart: number;
	periodEnd: number;
	models: PromptCacheModelStats[];
}

export interface TokenSeriesPoint {
	bucket: string;
	inputTokens: number;
	outputTokens: number;
}
