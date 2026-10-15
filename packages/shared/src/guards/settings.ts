import {
	MODEL_MAPPING_PROVIDERS,
	REASONING_BUDGET_TIERS,
	type ModelMappingProvider,
	type ReasoningBudgetTier
} from '../types/settings';

export function isModelMappingProvider(value: unknown): value is ModelMappingProvider {
	return typeof value === 'string' && MODEL_MAPPING_PROVIDERS.includes(value as ModelMappingProvider);
}

export function isReasoningBudgetTier(value: unknown): value is ReasoningBudgetTier {
	return typeof value === 'string' && REASONING_BUDGET_TIERS.includes(value as ReasoningBudgetTier);
}

export const MAX_MODEL_TOKEN_LIMIT = 100_000_000;

export function isModelTokenLimit(value: unknown): value is number {
	return typeof value === 'number' && Number.isSafeInteger(value) && value > 0 && value <= MAX_MODEL_TOKEN_LIMIT;
}
