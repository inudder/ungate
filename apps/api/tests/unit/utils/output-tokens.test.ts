import { describe, expect, it } from 'vitest';

import { openaiToAnthropic } from 'src/adapter/openai-to-anthropic';
import { CompletionModelRouting } from 'src/orchestration/openai';
import { resolveMaxOutputTokens } from 'src/utils/output-tokens';

import type { ModelMappingConfig } from '@ungate/shared';
import type { OpenAIChatRequest } from 'src/types/openai';

function request(fields: Partial<OpenAIChatRequest> = {}): OpenAIChatRequest {
	return { model: 'alias', messages: [{ role: 'user', content: 'hello' }], ...fields };
}

function mapping(fields: Partial<ModelMappingConfig>): ModelMappingConfig {
	return {
		id: 'alias',
		label: 'Alias',
		provider: 'claude',
		upstreamModel: 'claude-opus-4-8',
		sortOrder: 0,
		reasoningBudget: null,
		...fields
	};
}

describe('resolveMaxOutputTokens', () => {
	it('keeps the client value when the model has no cap', () => {
		expect(resolveMaxOutputTokens(50_000, null, 4096)).toBe(50_000);
	});

	it('caps the client value to the model limit', () => {
		expect(resolveMaxOutputTokens(500_000, 128_000, 4096)).toBe(128_000);
		expect(resolveMaxOutputTokens(2_000, 128_000, 4096)).toBe(2_000);
	});

	it('uses the model limit, then the fallback, when the client omits one', () => {
		expect(resolveMaxOutputTokens(undefined, 128_000, 4096)).toBe(128_000);
		expect(resolveMaxOutputTokens(undefined, null, 4096)).toBe(4096);
		expect(resolveMaxOutputTokens(0, undefined, 4096)).toBe(4096);
	});
});

describe('model output caps on upstream requests', () => {
	it('sends the Claude model cap when the client omits max_tokens', () => {
		const body = CompletionModelRouting.toAnthropicRequest(request(), mapping({ maxOutputTokens: 128_000 }));

		expect(body.max_tokens).toBe(128_000);
	});

	it('keeps the Claude fallback for models without a cap', () => {
		expect(openaiToAnthropic(request(), { model: 'claude-opus-4-8' }).max_tokens).toBe(4096);
	});

	it('caps MiniMax requests to the mapped model limit', () => {
		const body = CompletionModelRouting.buildMiniMaxBody(
			request({ max_tokens: 900_000 }),
			mapping({ provider: 'minimax', upstreamModel: 'MiniMax-M3', maxOutputTokens: 64_000 })
		);

		expect(body.model).toBe('MiniMax-M3');
		expect(body.max_completion_tokens).toBe(64_000);
	});
});
