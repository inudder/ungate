import { describe, expect, it, vi } from 'vitest';

import { ResponsesNonStreamSynthesizer, ResponsesStreamSynthesizer } from 'src/orchestration/responses';

const requestsRecordMock = vi.fn();

vi.mock('src/database/requests', () => ({
	Requests: {
		record: (...args: unknown[]) => requestsRecordMock(...args)
	}
}));

function sseResponse(events: string[]): Response {
	const stream = new ReadableStream<Uint8Array>({
		start(controller) {
			const encoder = new TextEncoder();
			controller.enqueue(encoder.encode(events.map((event) => `data: ${event}\n\n`).join('')));
			controller.close();
		}
	});

	return new Response(stream, { status: 200, headers: { 'content-type': 'text/event-stream' } });
}

function sseResponseWithUnterminatedFinalEvent(events: string[]): Response {
	const stream = new ReadableStream<Uint8Array>({
		start(controller) {
			const encoder = new TextEncoder();
			const body = events.map((event, index) => `data: ${event}${index === events.length - 1 ? '' : '\n\n'}`).join('');
			controller.enqueue(encoder.encode(body));
			controller.close();
		}
	});

	return new Response(stream, { status: 200, headers: { 'content-type': 'text/event-stream' } });
}

function context() {
	return {
		model: 'model-upstream',
		source: 'openai' as const,
		startTime: Date.now(),
		reverseToolMapping: {}
	};
}

async function readBody(stream: ReadableStream): Promise<string> {
	const reader = stream.getReader();
	const decoder = new TextDecoder();
	let text = '';

	while (true) {
		const { done, value } = await reader.read();
		if (done) break;
		text += decoder.decode(value);
	}

	return text;
}

describe('Responses synthesizers', () => {
	it('maps non-stream chat response text, tool calls, usage, and incomplete status', () => {
		const response = ResponsesNonStreamSynthesizer.synthesize(
			{
				id: 'chatcmpl_1',
				object: 'chat.completion',
				created: 123,
				model: 'gpt-up',
				choices: [
					{
						index: 0,
						message: {
							role: 'assistant',
							content: 'hello',
							tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'Read', arguments: '{"path":"a"}' } }]
						},
						finish_reason: 'length'
					}
				],
				usage: { prompt_tokens: 2, completion_tokens: 3, total_tokens: 5 }
			},
			'gpt-alias',
			'resp_test'
		);

		expect(response.id).toBe('resp_test');
		expect(response.status).toBe('incomplete');
		expect(response.incomplete_details).toEqual({ reason: 'max_output_tokens' });
		expect(response.output).toHaveLength(2);
		expect(response.usage).toEqual({ input_tokens: 2, output_tokens: 3, total_tokens: 5 });
	});

	it('collects chat SSE into a final Responses object preserving function calls', async () => {
		const response = await ResponsesStreamSynthesizer.collectStreamResponse({
			source: 'openai',
			response: sseResponse([
				'{"choices":[{"delta":{"role":"assistant"},"finish_reason":null}]}',
				'{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"Read","arguments":""}}]},"finish_reason":null}]}',
				'{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"path\\":\\"a\\"}"}}]},"finish_reason":null}]}',
				'{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}',
				'{"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":5,"total_tokens":9}}',
				'[DONE]'
			]),
			requestId: 'stream_test',
			model: 'gpt-alias',
			context: context()
		});

		expect(response.status).toBe('completed');
		expect(response.output).toEqual([
			expect.objectContaining({
				type: 'function_call',
				call_id: 'call_1',
				name: 'Read',
				arguments: '{"path":"a"}',
				status: 'completed'
			})
		]);
		expect(response.usage).toEqual({ input_tokens: 4, output_tokens: 5, total_tokens: 9 });
		expect(requestsRecordMock).toHaveBeenCalled();
	});

	it('restores mapped Codex Desktop tool names in streaming Responses output', async () => {
		const response = await ResponsesStreamSynthesizer.collectStreamResponse({
			source: 'claude',
			response: sseResponse([
				'{"type":"message_start","message":{"usage":{"input_tokens":4,"output_tokens":0}}}',
				'{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call_shell","name":"Bash","input":{}}}',
				'{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"cmd\\":\\"Get-PSDrive\\"}"}}',
				'{"type":"content_block_stop","index":0}',
				'{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}',
				'{"type":"message_stop"}'
			]),
			requestId: 'claude_tool_test',
			model: 'claude-alias',
			context: {
				...context(),
				source: 'claude',
				reverseToolMapping: { Bash: 'exec_command' }
			}
		});

		expect(response.output).toEqual([
			expect.objectContaining({
				type: 'function_call',
				call_id: 'call_shell',
				name: 'exec_command',
				arguments: '{"cmd":"Get-PSDrive"}'
			})
		]);
	});

	it('restores mapped Claude tool names in non-streaming Responses output', () => {
		const response = ResponsesNonStreamSynthesizer.synthesizeAnthropic(
			{
				id: 'msg_tool',
				type: 'message',
				role: 'assistant',
				content: [{ type: 'tool_use', id: 'call_shell', name: 'Bash', input: { command: 'Get-PSDrive' } }],
				model: 'claude-opus-4-8',
				stop_reason: 'tool_use',
				stop_sequence: null,
				usage: { input_tokens: 4, output_tokens: 5 }
			},
			'claude-alias',
			'claude_json_tool_test',
			{ Bash: 'shell_command' }
		);

		expect(response.output).toEqual([
			expect.objectContaining({
				type: 'function_call',
				call_id: 'call_shell',
				name: 'shell_command',
				arguments: '{"command":"Get-PSDrive"}'
			})
		]);
	});

	it('restores the Plan Mode question tool with structured arguments', () => {
		const response = ResponsesNonStreamSynthesizer.synthesizeAnthropic(
			{
				id: 'msg_question',
				type: 'message',
				role: 'assistant',
				content: [
					{
						type: 'tool_use',
						id: 'call_question',
						name: 'AskUserQuestion',
						input: {
							questions: [
								{
									id: 'downtime',
									header: 'Downtime',
									question: 'Stop the service?',
									options: [{ label: 'Stop', description: 'Safest restore.' }]
								}
							]
						}
					}
				],
				model: 'claude-opus-4-8',
				stop_reason: 'tool_use',
				stop_sequence: null,
				usage: { input_tokens: 4, output_tokens: 5 }
			},
			'claude-alias',
			'claude_question_test',
			{ AskUserQuestion: 'request_user_input' }
		);
		const toolCall = response.output[0];

		expect(toolCall).toEqual(
			expect.objectContaining({
				type: 'function_call',
				call_id: 'call_question',
				name: 'request_user_input'
			})
		);
		expect(JSON.parse('arguments' in toolCall ? toolCall.arguments : '{}')).toMatchObject({
			questions: [{ id: 'downtime', question: 'Stop the service?' }]
		});
	});

	it('emits Responses SSE event names without a chat DONE sentinel', async () => {
		const { stream } = ResponsesStreamSynthesizer.createResponseStream({
			source: 'openai',
			response: sseResponse([
				'{"choices":[{"delta":{"content":"hi"},"finish_reason":null}]}',
				'{"choices":[{"delta":{},"finish_reason":"stop"}]}'
			]),
			requestId: 'emit_test',
			model: 'gpt-alias',
			context: context()
		});
		const text = await readBody(stream);

		expect(text).toContain('event: response.created');
		expect(text).toContain('event: response.output_text.delta');
		expect(text).toContain('event: response.completed');
		expect(text).not.toContain('[DONE]');
	});

	it('drops MiniMax reasoning fragments and completes with final text', async () => {
		const { stream } = ResponsesStreamSynthesizer.createResponseStream({
			source: 'minimax',
			response: sseResponse([
				'{"choices":[{"delta":{"content":"<think>private reasoning"},"finish_reason":null}]}',
				'{"choices":[{"delta":{"content":"</think>OK","reasoning_content":"also private"},"finish_reason":null}]}',
				'{"choices":[{"delta":{},"finish_reason":"stop"}]}',
				'{"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}',
				'[DONE]'
			]),
			requestId: 'minimax_emit_test',
			model: 'miniMax-M3',
			context: {
				...context(),
				source: 'minimax'
			}
		});
		const text = await readBody(stream);

		expect(text).toContain('event: response.output_text.delta');
		expect(text).toContain('"delta":"OK"');
		expect(text).toContain('event: response.completed');
		expect(text).not.toContain('response.reasoning_summary_text.delta');
		expect(text).not.toContain('private reasoning');
		expect(text).not.toContain('also private');
	});

	it('flushes a MiniMax final SSE event without a blank delimiter', async () => {
		const { stream } = ResponsesStreamSynthesizer.createResponseStream({
			source: 'minimax',
			response: sseResponseWithUnterminatedFinalEvent([
				'{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_patch","type":"function","function":{"name":"mcp__ungate_patch__apply_patch"}}]},"finish_reason":null}]}',
				'{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"working_directory\\":\\"J:\\\\Dev\\\\project\\",\\"patch\\":\\"*** Begin Patch\\"}"}}]},"finish_reason":"tool_calls"}]}'
			]),
			requestId: 'minimax_tail_test',
			model: 'miniMax-M3',
			context: {
				...context(),
				source: 'minimax'
			}
		});
		const text = await readBody(stream);

		expect(text).toContain('response.function_call_arguments.done');
		expect(text).toContain('mcp__ungate_patch__apply_patch');
		expect(text).toContain('working_directory');
		expect(text).toContain('response.completed');
	});
});
