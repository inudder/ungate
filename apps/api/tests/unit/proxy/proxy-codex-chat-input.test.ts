import { describe, expect, it } from 'vitest';

import { CodexInputUtils } from 'src/proxy/codex-input-utils';

describe('proxy-codex-chat-input', () => {
	it('converts mixed openai messages into codex input preserving order with developer first', () => {
		const input = CodexInputUtils.buildFromMessages([
			{ role: 'user', content: 'u1' },
			{ role: 'system', content: 'sys' },
			{ role: 'assistant', content: 'a1' },
			{ role: 'tool', tool_call_id: 'call_1', content: 'result' },
			{
				role: 'assistant',
				content: 'a2',
				tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'Read', arguments: '{"path":"a"}' } }]
			}
		]);

		expect(input[0]).toMatchObject({ type: 'message', role: 'developer' });
		expect(input.some((item) => item.type === 'function_call')).toBe(true);
		expect(input.some((item) => item.type === 'function_call_output')).toBe(true);
	});

	it('normalizes assistant text blocks into output_text', () => {
		const normalized = CodexInputUtils.normalizeAssistantText([
			{
				type: 'message',
				role: 'assistant',
				content: [{ type: 'input_text', text: 'hello ' }, { type: 'text', text: 'world\n' }]
			}
		]);

		const content = normalized[0].content as Array<Record<string, unknown>>;
		expect(content[0].type).toBe('output_text');
		expect(content[0].text).toBe('hello');
		expect(content[1].type).toBe('output_text');
		expect(content[1].text).toBe('world');
	});

	it('expands mixed body.input items and coerces chat shape', () => {
		const expanded = CodexInputUtils.expandInput([
			{ role: 'system', content: 's' },
			{ type: 'message', role: 'user', content: [{ type: 'input_text', text: 'u' }] },
			{ type: 'function_call', call_id: 'c1', name: 'Read', arguments: '{}' }
		]);

		expect(expanded).toBeTruthy();
		expect(expanded?.[0]).toMatchObject({ type: 'message', role: 'developer' });
		expect(expanded?.at(-1)).toMatchObject({ type: 'function_call' });

		const coerced = CodexInputUtils.coerceMessages({
			input: [{ role: 'user', content: 'hi' }]
		});
		expect(coerced).toHaveLength(1);
		expect(coerced[0].role).toBe('user');
	});

	it('ignores reasoning items while preserving supported input order', () => {
		const expanded = CodexInputUtils.expandInput([
			{ type: 'reasoning', id: 'rs_1', summary: [{ type: 'summary_text', text: 'private' }] },
			{ type: 'message', role: 'user', content: [{ type: 'input_text', text: 'run tool' }] },
			{ type: 'reasoning', id: 'rs_2', summary: [{ type: 'summary_text', text: 'private again' }] },
			{ type: 'function_call', call_id: 'call_1', name: 'Read', arguments: '{}' },
			{ type: 'function_call_output', call_id: 'call_1', output: 'done' }
		]);

		expect(expanded).toEqual([
			{ type: 'message', role: 'user', content: [{ type: 'input_text', text: 'run tool' }] },
			{ type: 'function_call', call_id: 'call_1', name: 'Read', arguments: '{}' },
			{ type: 'function_call_output', call_id: 'call_1', output: 'done' }
		]);
	});

	it('rejects reasoning-only and unknown input items', () => {
		expect(
			CodexInputUtils.expandInput([{ type: 'reasoning', id: 'rs_only', summary: [{ type: 'summary_text', text: 'private' }] }])
		).toBeNull();
		expect(CodexInputUtils.expandInput([{ type: 'unsupported_item' }])).toBeNull();
	});
});
