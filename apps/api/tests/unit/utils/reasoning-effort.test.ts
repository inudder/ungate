import { describe, expect, it } from 'vitest';

import { normalizeModelName, openaiToAnthropic } from 'src/adapter/openai-to-anthropic';
import { CompletionModelRouting } from 'src/orchestration/openai';
import { ResponsesModelResolver } from 'src/proxy/responses-input-normalizer/resolve-model';
import { normalizeReasoningEffort, resolveReasoningEffort, withReasoningSelection } from 'src/utils/reasoning-effort';

import type { ModelMappingConfig } from '@ungate/shared';
import type { OpenAIChatRequest, OpenAIReasoningEffort } from 'src/types/openai';

function request(fields: Partial<OpenAIChatRequest> = {}): OpenAIChatRequest {
	return { model: 'custom-high', messages: [{ role: 'user', content: 'hello' }], ...fields };
}

function mapping(provider: ModelMappingConfig['provider']): ModelMappingConfig {
	return { id: 'custom-high', label: 'custom', provider, upstreamModel: 'gpt-5.4', reasoningBudget: 'high', sortOrder: 0 };
}

describe('reasoning effort', () => {
	it.each<OpenAIReasoningEffort>(['none', 'low', 'medium', 'high', 'xhigh', 'max'])(
		'preserves client %s over the default',
		(effort) => {
			expect(resolveReasoningEffort(request({ reasoning_effort: effort }), 'medium')).toEqual({ effort, source: 'client' });
			expect(resolveReasoningEffort(request({ reasoning: { effort } }), 'medium')).toEqual({ effort, source: 'client' });
		}
	);

	it('prefers nested effort and removes conflicting or null fields', () => {
		const body = request({ reasoning_effort: 'high', reasoning: { effort: 'low' } });
		const selection = resolveReasoningEffort(body, 'medium');
		expect(selection).toEqual({ effort: 'low', source: 'client' });
		expect(withReasoningSelection(body, selection)).toEqual(request({ reasoning: { effort: 'low' } }));
		expect(body.reasoning_effort).toBe('high');
		expect(withReasoningSelection(request({ reasoning: null, reasoning_effort: null }), { source: 'model_default' })).toEqual(
			request()
		);
	});

	it('inherits through null, empty objects, and absent values', () => {
		for (const fields of [
			{},
			{ reasoning: null },
			{ reasoning: {} },
			{ reasoning_effort: null },
			{ reasoning: { effort: null } }
		]) {
			expect(resolveReasoningEffort(request(fields), 'medium')).toEqual({ effort: 'medium', source: 'ungate' });
			expect(resolveReasoningEffort(request(fields), null)).toEqual({ source: 'model_default' });
		}
		expect(resolveReasoningEffort(request({ reasoning: { effort: null }, reasoning_effort: 'high' }), 'low').effort).toBe('high');
	});

	it.each(['', 'off', 'invalid', 'HIGH', 42, false])('rejects invalid effort %s', (effort) => {
		expect(() => normalizeReasoningEffort(effort)).toThrow('Invalid reasoning effort');
		expect(() => resolveReasoningEffort(request({ reasoning_effort: effort } as never), 'high')).toThrow(
			'Invalid reasoning effort'
		);
	});

	it('normalizes minimal only for Responses', () => {
		expect(normalizeReasoningEffort('minimal', true)).toBe('low');
		expect(() => normalizeReasoningEffort('minimal')).toThrow('Invalid reasoning effort');
	});

	it('keeps explicit fields ahead of recognized legacy suffixes and defaults', () => {
		const legacy = normalizeModelName('claude-4.6-sonnet-low');
		expect(resolveReasoningEffort(request(), 'high', legacy.reasoningBudget)).toEqual({ effort: 'low', source: 'client' });
		expect(resolveReasoningEffort(request({ reasoning_effort: 'max' }), 'high', 'low').effort).toBe('max');
		const claudeMapping = { ...mapping('claude'), upstreamModel: 'claude-sonnet-4-6' };
		expect(
			CompletionModelRouting.toAnthropicRequest(request({ model: 'claude-4.6-sonnet-low' }), claudeMapping).reasoning_budget
		).toBe('low');
		expect(
			CompletionModelRouting.toAnthropicRequest(
				request({ model: 'claude-4.6-sonnet-low', reasoning_effort: 'max' }),
				claudeMapping
			).reasoning_budget
		).toBe('max');
		expect(
			CompletionModelRouting.buildOpenAiUpstreamBody(request({ model: 'gpt-5.4-low' }), mapping('openai')).reasoning
		).toEqual({ effort: 'low' });
		expect(
			CompletionModelRouting.buildOpenAiUpstreamBody(
				request({ model: 'gpt-5.4-low', reasoning_effort: 'max' }),
				mapping('openai')
			).reasoning
		).toEqual({ effort: 'max' });
	});

	it('converts Claude none to disabled and preserves max without mutating the request', () => {
		const override = { model: 'claude-sonnet-5-5', reasoningBudget: 'high' as const };
		const disabled = openaiToAnthropic(request({ reasoning_effort: 'none' }), override);
		expect(disabled.thinking).toEqual({ type: 'disabled' });
		expect(disabled.reasoning_budget).toBeUndefined();
		const maximum = openaiToAnthropic(request({ reasoning_effort: 'max' }), override);
		expect(maximum.reasoning_budget).toBe('max');
		expect(openaiToAnthropic(request(), { ...override, reasoningBudget: null }).reasoning_budget).toBeUndefined();
	});

	it.each(['openai', 'minimax'] as const)('normalizes conflicting fields for %s', (provider) => {
		const body = request({ reasoning_effort: 'high', reasoning: { effort: 'low' } });
		const selectedMapping = mapping(provider);
		const result =
			provider === 'openai'
				? CompletionModelRouting.buildOpenAiUpstreamBody(body, selectedMapping)
				: CompletionModelRouting.buildMiniMaxBody(body, selectedMapping);
		expect(result.reasoning).toEqual({ effort: 'low' });
		expect(result.reasoning_effort).toBeUndefined();
	});

	it('does not parse arbitrary mapped IDs as reasoning suffixes', () => {
		expect(ResponsesModelResolver.resolveReasoningSuffix('custom-high')).toBeNull();
		expect(CompletionModelRouting.buildOpenAiUpstreamBody(request(), mapping('openai')).reasoning).toEqual({ effort: 'high' });
		expect(ResponsesModelResolver.resolveModel('gpt-5.3-codex')).toEqual({ model: 'gpt-5.3-codex' });
		expect(ResponsesModelResolver.resolveModel('gpt-5.1')).toEqual({ model: 'gpt-5.1-codex-mini' });
	});
});
