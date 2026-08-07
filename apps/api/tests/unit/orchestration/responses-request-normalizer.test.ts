import { describe, expect, it, vi } from 'vitest';

import { ResponsesRequestNormalizer, ResponsesRequestValidationError, itemsToChatMessages } from 'src/orchestration/responses';

const resolveForChatCompletionMock = vi.fn();

vi.mock('src/database/model-mappings', () => ({
	ModelMappings: {
		resolveForChatCompletion: (...args: unknown[]) => resolveForChatCompletionMock(...args)
	}
}));

describe('ResponsesRequestNormalizer', () => {
	it('maps instructions, string input, docs-correct tools, token floor, and minimal reasoning', () => {
		resolveForChatCompletionMock.mockReturnValueOnce(null);

		const result = ResponsesRequestNormalizer.toChatRequest({
			model: 'gpt-alias',
			instructions: 'be precise',
			input: 'hello',
			max_output_tokens: 321,
			reasoning: { effort: 'minimal' },
			tools: [{ type: 'function', name: 'ReadFile', description: 'read', parameters: { type: 'object' } }],
			tool_choice: { type: 'function', name: 'ReadFile' },
			parallel_tool_calls: false
		});

		expect(result.body.messages).toEqual([
			{ role: 'system', content: 'be precise' },
			{ role: 'user', content: 'hello' }
		]);
		expect(result.body.max_completion_tokens).toBe(8192);
		expect(result.body.reasoning).toEqual({ effort: 'low' });
		expect(result.body.tools).toEqual([
			{
				type: 'function',
				function: {
					name: 'ReadFile',
					description: 'read',
					parameters: { type: 'object' },
					strict: undefined
				}
			}
		]);
		expect(result.body.tool_choice).toEqual({ type: 'function', function: { name: 'ReadFile' } });
		expect((result.body as { parallel_tool_calls?: boolean }).parallel_tool_calls).toBe(false);
		expect(resolveForChatCompletionMock).toHaveBeenCalledWith('gpt-alias');
	});

	it('preserves Responses max_output_tokens above the Codex floor', () => {
		resolveForChatCompletionMock.mockReturnValueOnce(null);

		const result = ResponsesRequestNormalizer.toChatRequest({
			model: 'gpt-alias',
			input: 'hello',
			max_output_tokens: 12000
		});

		expect(result.body.max_completion_tokens).toBe(12000);
	});

	it('ignores reasoning items when normalizing a continuation input', () => {
		resolveForChatCompletionMock.mockReturnValueOnce(null);

		const result = ResponsesRequestNormalizer.toChatRequest({
			model: 'gpt-alias',
			input: [
				{ type: 'reasoning', id: 'rs_1', summary: [{ type: 'summary_text', text: 'private' }] },
				{ type: 'message', role: 'user', content: [{ type: 'input_text', text: 'continue' }] }
			]
		});

		expect(result.body.messages).toEqual([{ role: 'user', content: 'continue' }]);
	});

	it('treats reasoning-only continuation input as empty input', () => {
		resolveForChatCompletionMock.mockReturnValueOnce(null);

		expect(() =>
			ResponsesRequestNormalizer.toChatRequest({
				model: 'gpt-alias',
				input: [{ type: 'reasoning', id: 'rs_only', summary: [{ type: 'summary_text', text: 'private' }] }]
			})
		).toThrow(
			expect.objectContaining<ResponsesRequestValidationError>({
				code: 'empty_input',
				message: 'Responses input must not be empty'
			})
		);
	});

	it('passes flattened MCP namespace tools to chat providers', () => {
		resolveForChatCompletionMock.mockReturnValueOnce({ provider: 'minimax', upstreamModel: 'mini-up' });

		const result = ResponsesRequestNormalizer.toChatRequest({
			model: 'miniMax-M3',
			input: 'apply it',
			tools: [
				{
					type: 'namespace',
					name: 'mcp__ungate_patch',
					tools: [
						{
							type: 'function',
							name: 'apply_patch',
							inputSchema: { type: 'object', properties: { patch: { type: 'string' } } }
						}
					]
				}
			]
		});

		expect(result.body.tools).toEqual([
			{
				type: 'function',
				function: {
					name: 'mcp__ungate_patch__apply_patch',
					description: undefined,
					parameters: { type: 'object', properties: { patch: { type: 'string' } } },
					strict: undefined
				}
			}
		]);
	});

	it('turns function_call and function_call_output items into chat messages', () => {
		const messages = itemsToChatMessages([
			{ type: 'message', role: 'user', content: [{ type: 'input_text', text: 'run tool' }] },
			{ type: 'function_call', call_id: 'call_1', name: 'Lookup', arguments: '{"q":"x"}' },
			{ type: 'function_call_output', call_id: 'call_1', output: 'done' }
		]);

		expect(messages).toEqual([
			{ role: 'user', content: 'run tool' },
			{
				role: 'assistant',
				content: null,
				tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'Lookup', arguments: '{"q":"x"}' } }]
			},
			{ role: 'tool', tool_call_id: 'call_1', content: 'done' }
		]);
	});

	it('groups adjacent function calls into one assistant tool-call message', () => {
		const messages = itemsToChatMessages([
			{ type: 'function_call', call_id: 'call_1', name: 'Read', arguments: '{"path":"a"}' },
			{ type: 'function_call', call_id: 'call_2', name: 'List', arguments: '{"path":"b"}' },
			{ type: 'function_call', call_id: 'call_3', name: 'Search', arguments: '{"query":"c"}' },
			{ type: 'function_call_output', call_id: 'call_1', output: 'a' },
			{ type: 'function_call_output', call_id: 'call_2', output: 'b' },
			{ type: 'function_call_output', call_id: 'call_3', output: 'c' }
		]);

		expect(messages).toEqual([
			{
				role: 'assistant',
				content: null,
				tool_calls: [
					{ id: 'call_1', type: 'function', function: { name: 'Read', arguments: '{"path":"a"}' } },
					{ id: 'call_2', type: 'function', function: { name: 'List', arguments: '{"path":"b"}' } },
					{ id: 'call_3', type: 'function', function: { name: 'Search', arguments: '{"query":"c"}' } }
				]
			},
			{ role: 'tool', tool_call_id: 'call_1', content: 'a' },
			{ role: 'tool', tool_call_id: 'call_2', content: 'b' },
			{ role: 'tool', tool_call_id: 'call_3', content: 'c' }
		]);
	});

	it('merges assistant commentary with tool calls before their tool results', () => {
		const messages = itemsToChatMessages([
			{ type: 'function_call', call_id: 'call_1', name: 'Shell', arguments: '{"command":"Get-Date"}' },
			{
				type: 'message',
				role: 'assistant',
				content: [{ type: 'output_text', text: 'I found the log. Checking the latest entries.' }]
			},
			{ type: 'function_call_output', call_id: 'call_1', output: 'done' }
		]);

		expect(messages).toEqual([
			{
				role: 'assistant',
				content: 'I found the log. Checking the latest entries.',
				tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'Shell', arguments: '{"command":"Get-Date"}' } }]
			},
			{ role: 'tool', tool_call_id: 'call_1', content: 'done' }
		]);
	});

	it('does not group function calls separated by a tool result', () => {
		const messages = itemsToChatMessages([
			{ type: 'function_call', call_id: 'call_1', name: 'Read', arguments: '{}' },
			{ type: 'function_call_output', call_id: 'call_1', output: 'done' },
			{ type: 'function_call', call_id: 'call_2', name: 'Write', arguments: '{}' }
		]);

		expect(messages.filter((message) => message.role === 'assistant')).toHaveLength(2);
	});

	it('accepts previous_response_id as a stateless hint', () => {
		const result = ResponsesRequestNormalizer.toChatRequest({
			model: 'gpt-alias',
			input: 'hello',
			previous_response_id: 'resp_old'
		});

		expect(result.body.messages.at(-1)).toEqual({ role: 'user', content: 'hello' });
	});

	it('converts Responses input_image parts into OpenAI image_url chat content', () => {
		const result = itemsToChatMessages([
			{
				type: 'message',
				role: 'user',
				content: [
					{ type: 'input_text', text: 'look' },
					{ type: 'input_image', image_url: 'data:image/png;base64,abc', detail: 'high' }
				]
			}
		]);

		expect(result).toEqual([
			{
				role: 'user',
				content: [
					{ type: 'text', text: 'look' },
					{ type: 'image_url', image_url: { url: 'data:image/png;base64,abc', detail: 'high' } }
				]
			}
		]);
	});
});
