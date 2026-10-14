import type { ModelMappingProvider } from './settings';

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
	provider: ModelMappingProvider;
	requests: number;
	cacheHitRequests: number;
	cacheWriteRequests: number;
	inputTokens: number;
	cacheReadTokens: number;
	cacheCreationTokens: number;
	/** Cache reads / input tokens; input includes cached tokens for every provider. */
	cachedInputShare: number;
	/** Only Claude reports cache writes; the write columns and reuse rate are meaningless otherwise. */
	reportsCacheWrites: boolean;
	/** Cache reads / (reads + writes); null when the provider does not report cache writes. */
	reuseRate: number | null;
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
