import { logger } from './logger';

import type { OpenAIChatRequest, OpenAIReasoningEffort } from 'src/types/openai';

const VALID_EFFORTS: readonly OpenAIReasoningEffort[] = ['none', 'low', 'medium', 'high', 'xhigh', 'max'];

export interface ReasoningSelection {
	effort?: OpenAIReasoningEffort;
	source: 'client' | 'ungate' | 'model_default';
}

export function normalizeReasoningEffort(value: unknown, allowMinimal = false): OpenAIReasoningEffort | undefined {
	if (value === undefined || value === null) {
		return undefined;
	}

	if (allowMinimal && value === 'minimal') {
		return 'low';
	}

	if (typeof value !== 'string' || !VALID_EFFORTS.includes(value as OpenAIReasoningEffort)) {
		throw new Error('Invalid reasoning effort. Expected none, low, medium, high, xhigh, or max.');
	}

	return value as OpenAIReasoningEffort;
}

export function resolveReasoningEffort(
	body: OpenAIChatRequest,
	defaultEffort?: OpenAIReasoningEffort | null,
	legacyEffort?: OpenAIReasoningEffort
): ReasoningSelection {
	const clientEffort = normalizeReasoningEffort(body.reasoning?.effort ?? body.reasoning_effort) ?? legacyEffort;

	if (clientEffort !== undefined) {
		return { effort: clientEffort, source: 'client' };
	}

	if (defaultEffort !== undefined && defaultEffort !== null) {
		return { effort: defaultEffort, source: 'ungate' };
	}

	return { source: 'model_default' };
}

export function withReasoningSelection(body: OpenAIChatRequest, selection: ReasoningSelection): OpenAIChatRequest {
	if (selection.effort === undefined && !('reasoning' in body) && !('reasoning_effort' in body)) {
		return body;
	}

	const normalized = { ...body };
	delete normalized.reasoning_effort;
	delete normalized.reasoning;

	if (selection.effort !== undefined) {
		normalized.reasoning = { ...body.reasoning, effort: selection.effort };
	}

	return normalized;
}

export function logReasoningSelection(provider: string, model: string, selection: ReasoningSelection): void {
	logger.log(
		`[Reasoning] provider=${provider} model=${model} effort=${selection.effort ?? 'default'} source=${selection.source}`
	);
}
