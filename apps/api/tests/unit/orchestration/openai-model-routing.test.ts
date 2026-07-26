import { describe, expect, it } from 'vitest';

import { CompletionModelRouting } from 'src/orchestration/openai';

import type { ModelMappingConfig } from '@ungate/shared';

function mapping(partial: Partial<ModelMappingConfig> & Pick<ModelMappingConfig, 'provider' | 'upstreamModel'>): ModelMappingConfig {
	return {
		id: partial.id ?? 'id',
		label: partial.label ?? 'label',
		provider: partial.provider,
		upstreamModel: partial.upstreamModel,
		sortOrder: partial.sortOrder ?? 0,
		reasoningBudget: partial.reasoningBudget ?? null
	};
}

describe('CompletionModelRouting', () => {
	it('detects minimax model prefixes case-insensitively', () => {
		expect(CompletionModelRouting.isMiniMaxModel('MiniMax-x')).toBe(true);
		expect(CompletionModelRouting.isMiniMaxModel('  mini-max-1  ')).toBe(true);
		expect(CompletionModelRouting.isMiniMaxModel('gpt-4')).toBe(false);
	});

	it('routes minimax when mapping says minimax or model prefix matches', () => {
		expect(CompletionModelRouting.shouldRouteMiniMax(mapping({ provider: 'minimax', upstreamModel: 'u' }), 'x')).toBe(true);
		expect(CompletionModelRouting.shouldRouteMiniMax(null, 'minimax-pro')).toBe(true);
		expect(CompletionModelRouting.shouldRouteMiniMax(null, 'claude')).toBe(false);
	});

	it('builds minimax body only when mapping provider is minimax', () => {
		const body = { model: 'alias', messages: [], stream: false } as const;
		const mm = mapping({ provider: 'minimax', upstreamModel: 'upstream-mm' });

		expect(CompletionModelRouting.buildMiniMaxBody(body as never, mm).model).toBe('upstream-mm');
		expect(CompletionModelRouting.buildMiniMaxBody(body as never, null).model).toBe('alias');
	});

	it('adds MiniMax file-editing guidance after leading system messages when an edit tool is available', () => {
		const body = {
			model: 'alias',
			messages: [
				{ role: 'system', content: 'base instruction' },
				{ role: 'developer', content: 'project instruction' },
				{ role: 'user', content: 'edit a file' }
			],
			tools: [
				{
					type: 'function',
					function: { name: 'exec_command', parameters: { type: 'object' } }
				}
			]
		} as const;

		const upstream = CompletionModelRouting.buildMiniMaxBody(body as never, null);
		const instruction = upstream.messages[2];
		const instructionContent = instruction?.content;

		expect(upstream.messages).toEqual([
			{ role: 'system', content: 'base instruction' },
			{ role: 'developer', content: 'project instruction' },
			expect.objectContaining({ role: 'system', content: expect.any(String) }),
			{ role: 'user', content: 'edit a file' }
		]);
		expect(typeof instructionContent).toBe('string');

		if (typeof instructionContent !== 'string') {
			throw new Error('MiniMax instruction must be text');
		}

		expect(instructionContent).toContain('mcp__ungate_patch__apply_patch appears in the tool list');
		expect(instructionContent).toContain('*** Add File: relative/path\n+content');
		expect(instructionContent).toContain('exactly one ASCII space after the colon');
		expect(instructionContent).toContain('literal + in column 1');
		expect(instructionContent).toContain('Do not add @@');
		expect(instructionContent).toContain('*** Update File: relative/path\n@@\n unchanged context');
		expect(instructionContent).toContain('Never emit a raw empty line inside a hunk');
		expect(instructionContent).toContain('line containing exactly one ASCII space');
		expect(instructionContent).toContain('research and planning are intermediate work, not task completion');
		expect(instructionContent).toContain('do not return a prose-only message');
		expect(instructionContent).toContain('inspect the required context, edit through the available patch tool, run relevant checks');
		expect(instructionContent).toContain('a user decision is required');
		expect(body.messages).toHaveLength(3);
	});

	it('does not add MiniMax file-editing guidance without a compatible exec_command tool', () => {
		const body = { model: 'alias', messages: [{ role: 'user', content: 'hello' }], tools: [] } as const;

		expect(CompletionModelRouting.buildMiniMaxBody(body as never, null)).toBe(body);
	});

	it('adds MiniMax file-editing guidance when the MCP patch tool is available without exec_command', () => {
		const body = {
			model: 'alias',
			messages: [{ role: 'user', content: 'edit a file' }],
			tools: [
				{
					type: 'function',
					function: { name: 'mcp__ungate_patch__apply_patch', parameters: { type: 'object' } }
				}
			]
		} as const;

		const upstream = CompletionModelRouting.buildMiniMaxBody(body as never, null);

		expect(upstream.messages).toHaveLength(2);
		expect(upstream.messages[0]).toEqual(expect.objectContaining({ role: 'system', content: expect.stringContaining('mcp__ungate_patch__apply_patch') }));
	});

	it('injects reasoning from model mapping into minimax body when client omits it', () => {
		const body = { model: 'alias', messages: [], stream: false } as const;
		const mm = mapping({ provider: 'minimax', upstreamModel: 'upstream-mm', reasoningBudget: 'xhigh' });

		const upstream = CompletionModelRouting.buildMiniMaxBody(body as never, mm);

		expect(upstream.reasoning).toEqual({ effort: 'xhigh' });
	});

	it('preserves client-provided reasoning over model mapping reasoning budget for minimax', () => {
		const body = { model: 'alias', messages: [], stream: false, reasoning: { effort: 'low' } } as const;
		const mm = mapping({ provider: 'minimax', upstreamModel: 'upstream-mm', reasoningBudget: 'xhigh' });

		const upstream = CompletionModelRouting.buildMiniMaxBody(body as never, mm);

		expect(upstream.reasoning).toEqual({ effort: 'low' });
	});

	it('does not inject reasoning when minimax mapping has no reasoning budget', () => {
		const body = { model: 'alias', messages: [], stream: false } as const;
		const mm = mapping({ provider: 'minimax', upstreamModel: 'upstream-mm', reasoningBudget: null });

		const upstream = CompletionModelRouting.buildMiniMaxBody(body as never, mm);

		expect('reasoning' in upstream).toBe(false);
	});

	it('narrows openai mapping with isOpenAiMapped', () => {
		const openai = mapping({ provider: 'openai', upstreamModel: 'gpt-up' });

		expect(CompletionModelRouting.isOpenAiMapped(openai)).toBe(true);
		expect(CompletionModelRouting.isOpenAiMapped(null)).toBe(false);
		expect(CompletionModelRouting.isOpenAiMapped(mapping({ provider: 'claude', upstreamModel: 'c' }))).toBe(false);
	});

	it('builds openai upstream body with optional reasoning effort', () => {
		const body = { model: 'alias', messages: [], stream: false } as const;
		const openai = mapping({ provider: 'openai', upstreamModel: 'gpt-real', reasoningBudget: 'high' });
		const upstream = CompletionModelRouting.buildOpenAiUpstreamBody(body as never, openai);

		expect(upstream.model).toBe('gpt-real');
		expect(upstream.reasoning).toEqual({ effort: 'high' });

		const noBudget = mapping({ provider: 'openai', upstreamModel: 'gpt-2', reasoningBudget: null });
		const plain = CompletionModelRouting.buildOpenAiUpstreamBody(body as never, noBudget);

		expect(plain.model).toBe('gpt-2');
		expect('reasoning' in plain).toBe(false);
	});
});
