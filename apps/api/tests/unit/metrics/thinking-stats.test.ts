import { afterEach, describe, expect, it, vi } from 'vitest';

import { ThinkingStats, anthropicThinkingEffort, chatThinkingEffort, logThinkingSummary } from 'src/metrics/thinking-stats';

import type { AnthropicRequest } from 'src/types';

function anthropicBody(overrides: Partial<AnthropicRequest>): AnthropicRequest {
	return { model: 'claude-opus-5-5', max_tokens: 1024, messages: [], ...overrides };
}

describe('ThinkingStats', () => {
	afterEach(() => {
		vi.restoreAllMocks();
	});

	it('counts Anthropic response blocks without keeping their text', () => {
		const stats = new ThinkingStats('high');

		for (const block of [
			{ type: 'thinking', thinking: 'first', signature: 's' },
			{ type: 'text', text: 'answer' },
			{ type: 'redacted_thinking', data: 'enc' },
			{ type: 'thinking', thinking: 'second!' }
		]) {
			stats.observeAnthropicBlock(block);
		}

		expect(stats).toMatchObject({ blocks: 2, chars: 12, redactedBlocks: 1 });
		expect(JSON.stringify(stats)).not.toContain('first');
	});

	it('treats a run of reasoning deltas as one block', () => {
		const stats = new ThinkingStats();

		stats.reasoningDelta('ab');
		stats.reasoningDelta('cd');
		stats.endReasoning();
		stats.reasoningDelta('e');
		stats.reasoningDelta('');

		expect(stats).toMatchObject({ blocks: 2, chars: 5 });
	});

	it('resolves the requested effort from Anthropic and chat bodies', () => {
		expect(anthropicThinkingEffort(anthropicBody({ thinking: { type: 'disabled' } }))).toBe('none');
		expect(anthropicThinkingEffort(anthropicBody({ thinking: { type: 'adaptive' }, output_config: { effort: 'xhigh' } }))).toBe(
			'xhigh'
		);
		expect(anthropicThinkingEffort(anthropicBody({ reasoning_budget: 'medium' }))).toBe('medium');
		expect(anthropicThinkingEffort(anthropicBody({ thinking: { type: 'enabled', budget_tokens: 8000 } }))).toBe('budget:8000');
		expect(anthropicThinkingEffort(anthropicBody({}))).toBeUndefined();

		expect(chatThinkingEffort({ model: 'm', messages: [], reasoning: { effort: 'low' } })).toBe('low');
		expect(chatThinkingEffort({ model: 'm', messages: [], reasoning_effort: 'high' })).toBe('high');
		expect(chatThinkingEffort({ model: 'm', messages: [] })).toBeUndefined();
	});

	it('logs one summary line with effort, blocks, chars and reasoning tokens', () => {
		const log = vi.spyOn(console, 'log').mockImplementation(() => {});
		const stats = new ThinkingStats('high');
		stats.reasoningDelta('12345');

		logThinkingSummary('gpt-6.1-sol', stats, 812);

		expect(log).toHaveBeenCalledWith('[Thinking] model=gpt-6.1-sol effort=high blocks=1 chars=5 reasoning_tokens=812');
	});

	it('reports redacted blocks and missing token counts', () => {
		const log = vi.spyOn(console, 'log').mockImplementation(() => {});
		const stats = new ThinkingStats();
		stats.observeAnthropicBlock({ type: 'redacted_thinking', data: 'enc' });

		logThinkingSummary('claude-opus-5-5', stats, null);

		expect(log).toHaveBeenCalledWith(
			'[Thinking] model=claude-opus-5-5 effort=default blocks=0 chars=0 redacted=1 reasoning_tokens=n/a'
		);
	});

	it('stays silent when thinking was neither requested nor produced', () => {
		const log = vi.spyOn(console, 'log').mockImplementation(() => {});

		logThinkingSummary('m', undefined);
		logThinkingSummary('m', new ThinkingStats());
		logThinkingSummary('m', new ThinkingStats('none'), 0);

		expect(log).not.toHaveBeenCalled();
	});
});
