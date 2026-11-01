export type ReasoningBudgetTier = 'low' | 'medium' | 'high' | 'xhigh' | 'max';

export type ModelMappingProvider = 'claude' | 'minimax' | 'openai';

export const MODEL_MAPPING_PROVIDERS = ['claude', 'minimax', 'openai'] as const;
export const REASONING_BUDGET_TIERS = ['low', 'medium', 'high', 'xhigh', 'max'] as const;

export interface ModelMappingConfig {
	id: string;
	label: string;
	provider: ModelMappingProvider;
	upstreamModel: string;
	sortOrder: number;
	reasoningBudget: ReasoningBudgetTier | null;
	/** Input context window in tokens; null leaves it unknown to clients. */
	contextWindow?: number | null;
	/** Output token cap; used when the client omits one and to clamp larger requests. */
	maxOutputTokens?: number | null;
}

export interface ProviderModelCatalogItem {
	upstreamModel: string;
	label: string;
	contextWindow?: number;
	maxOutputTokens?: number;
}

export interface ProviderModelsResponse {
	provider: ModelMappingProvider;
	models: ProviderModelCatalogItem[];
}

export interface AppSettings {
	port: number;
	apiKey: string | null;
	quiet: boolean;
	extraInstruction: string | null;
	models: ModelMappingConfig[];
}

export interface ModelValidationResult {
	ok: boolean;
	available: boolean;
	message: string;
	provider: ModelMappingProvider;
	upstreamModel: string;
	statusCode?: number;
	latencyMs?: number;
}
