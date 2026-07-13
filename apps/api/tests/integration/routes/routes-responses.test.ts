import { afterEach, describe, expect, it, vi } from 'vitest';

import responsesPlugin from 'src/routes/responses';

import { withPlugin } from '../test-harness';

const resolveForChatCompletionMock = vi.fn();
const proxyMiniMaxRequestMock = vi.fn();
const proxyOpenAIRequestMock = vi.fn();
const proxyRequestMock = vi.fn();
const requestsRecordMock = vi.fn();

vi.mock('src/database/model-mappings', () => ({
	ModelMappings: {
		resolveForChatCompletion: (...args: unknown[]) => resolveForChatCompletionMock(...args)
	}
}));

vi.mock('src/proxy/minimax-client', () => ({
	proxyMiniMaxRequest: (...args: unknown[]) => proxyMiniMaxRequestMock(...args)
}));

vi.mock('src/proxy/proxy-client', () => ({
	proxyOpenAIRequest: (...args: unknown[]) => proxyOpenAIRequestMock(...args)
}));

vi.mock('src/proxy/anthropic-client', () => ({
	proxyRequest: (...args: unknown[]) => proxyRequestMock(...args)
}));

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

describe('routes-responses', () => {
	afterEach(() => {
		vi.clearAllMocks();
	});

	it('routes to MiniMax and returns a Responses JSON object', async () => {
		resolveForChatCompletionMock.mockReturnValueOnce({ provider: 'minimax', upstreamModel: 'mini-up' });
		proxyMiniMaxRequestMock.mockResolvedValueOnce({
			response: new Response(
				JSON.stringify({
					id: 'chatcmpl-mini',
					object: 'chat.completion',
					created: 123,
					model: 'mini-up',
					choices: [{ index: 0, message: { role: 'assistant', content: 'ok' }, finish_reason: 'stop' }],
					usage: { prompt_tokens: 1, completion_tokens: 2, total_tokens: 3 }
				}),
				{ status: 200, headers: { 'content-type': 'application/json' } }
			),
			context: {
				startTime: Date.now(),
				model: 'mini-up',
				source: 'minimax',
				reverseToolMapping: {},
				inputTokens: 1,
				outputTokens: 2
			}
		});

		const app = await withPlugin(responsesPlugin, { apiKey: 'secret' });
		const response = await app.inject({
			method: 'POST',
			url: '/v1/responses',
			headers: { 'x-api-key': 'secret' },
			payload: {
				model: 'minimax-alias',
				input: 'hi',
				tools: [{ type: 'function', name: 'exec_command', parameters: { type: 'object' } }]
			}
		});

		expect(response.statusCode).toBe(200);
		expect(response.json()).toMatchObject({
			object: 'response',
			model: 'minimax-alias',
			status: 'completed',
			output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'ok', annotations: [] }] }],
			usage: { input_tokens: 1, output_tokens: 2, total_tokens: 3 }
		});
		expect(proxyMiniMaxRequestMock).toHaveBeenCalledWith(
			expect.objectContaining({
				model: 'mini-up',
				messages: expect.arrayContaining([
					expect.objectContaining({
						role: 'system',
						content: expect.stringContaining('apply_patch custom tool is unavailable')
					})
				])
			})
		);
		expect(requestsRecordMock).toHaveBeenCalled();
		await app.close();
	});

	it('accepts multimodal request bodies larger than the Fastify 1 MiB default', async () => {
		resolveForChatCompletionMock.mockReturnValueOnce({ provider: 'minimax', upstreamModel: 'mini-up' });
		proxyMiniMaxRequestMock.mockResolvedValueOnce({
			response: new Response(
				JSON.stringify({
					id: 'chatcmpl-large-image',
					object: 'chat.completion',
					created: 123,
					model: 'mini-up',
					choices: [{ index: 0, message: { role: 'assistant', content: 'visible' }, finish_reason: 'stop' }],
					usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 }
				}),
				{ status: 200, headers: { 'content-type': 'application/json' } }
			),
			context: {
				startTime: Date.now(),
				model: 'mini-up',
				source: 'minimax',
				reverseToolMapping: {},
				inputTokens: 1,
				outputTokens: 1
			}
		});

		const app = await withPlugin(responsesPlugin, { apiKey: 'secret' });
		const response = await app.inject({
			method: 'POST',
			url: '/v1/responses',
			headers: { 'x-api-key': 'secret' },
			payload: {
				model: 'minimax-alias',
				input: [
					{
						type: 'message',
						role: 'user',
						content: [
							{ type: 'input_text', text: 'describe' },
							{ type: 'input_image', image_url: `data:image/png;base64,${'a'.repeat(1024 * 1024)}` }
						]
					}
				]
			}
		});

		expect(response.statusCode).toBe(200);
		expect(proxyMiniMaxRequestMock).toHaveBeenCalledWith(
			expect.objectContaining({
				messages: expect.arrayContaining([
					expect.objectContaining({
						content: expect.arrayContaining([
							expect.objectContaining({ type: 'image_url', image_url: expect.objectContaining({ url: expect.any(String) }) })
						])
					})
				])
			})
		);
		await app.close();
	});

	it('routes MiniMax streaming responses as valid Responses SSE without reasoning summaries', async () => {
		resolveForChatCompletionMock.mockReturnValueOnce({ provider: 'minimax', upstreamModel: 'mini-up' });
		proxyMiniMaxRequestMock.mockResolvedValueOnce({
			response: sseResponse([
				'{"choices":[{"delta":{"content":"<think>private</think>ok"},"finish_reason":null}]}',
				'{"choices":[{"delta":{},"finish_reason":"stop"}]}',
				'{"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}',
				'[DONE]'
			]),
			context: {
				startTime: Date.now(),
				model: 'mini-up',
				source: 'minimax',
				reverseToolMapping: {}
			}
		});

		const app = await withPlugin(responsesPlugin, { apiKey: 'secret' });
		const response = await app.inject({
			method: 'POST',
			url: '/v1/responses',
			headers: { authorization: 'Bearer secret' },
			payload: { model: 'minimax-alias', input: 'hello', stream: true }
		});

		expect(response.statusCode).toBe(200);
		expect(response.headers['content-type']).toContain('text/event-stream');
		expect(response.body).toContain('event: response.output_text.delta');
		expect(response.body).toContain('"delta":"ok"');
		expect(response.body).toContain('event: response.completed');
		expect(response.body).not.toContain('response.reasoning_summary_text.delta');
		expect(response.body).not.toContain('private');
		expect(response.body).not.toContain('[DONE]');
		expect(requestsRecordMock).toHaveBeenCalled();
		await app.close();
	});

	it('returns a visible API error for a MiniMax semantic error returned with HTTP 200 upstream', async () => {
		resolveForChatCompletionMock.mockReturnValueOnce({ provider: 'minimax', upstreamModel: 'mini-up' });
		proxyMiniMaxRequestMock.mockResolvedValueOnce({
			response: new Response(JSON.stringify({ error: { message: 'MiniMax error 2013: invalid params', type: 'api_error', code: '2013' } }), {
				status: 502,
				headers: { 'content-type': 'application/json' }
			}),
			context: {
				startTime: Date.now(),
				model: 'mini-up',
				source: 'minimax',
				reverseToolMapping: {},
				bodyJson: { error: { message: 'MiniMax error 2013: invalid params', code: '2013' } }
			}
		});

		const app = await withPlugin(responsesPlugin, { apiKey: 'secret' });
		const response = await app.inject({
			method: 'POST',
			url: '/v1/responses',
			headers: { authorization: 'Bearer secret' },
			payload: { model: 'minimax-alias', input: 'continue', stream: true }
		});

		expect(response.statusCode).toBe(502);
		expect(response.json()).toEqual({
			error: { message: 'MiniMax error 2013: invalid params', type: 'api_error', code: '2013' }
		});
		await app.close();
	});

	it('routes OpenAI-mapped non-stream requests through upstream stream and preserves tool calls', async () => {
		resolveForChatCompletionMock.mockReturnValueOnce({
			provider: 'openai',
			upstreamModel: 'gpt-up',
			reasoningBudget: null
		});
		proxyOpenAIRequestMock.mockResolvedValueOnce({
			response: sseResponse([
				'{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"Read","arguments":""}}]},"finish_reason":null}]}',
				'{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"path\\":\\"a\\"}"}}]},"finish_reason":null}]}',
				'{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}',
				'{"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7}}',
				'[DONE]'
			]),
			context: {
				startTime: Date.now(),
				model: 'gpt-up',
				source: 'openai',
				reverseToolMapping: {}
			}
		});

		const app = await withPlugin(responsesPlugin, { apiKey: 'secret' });
		const response = await app.inject({
			method: 'POST',
			url: '/v1/responses',
			headers: { authorization: 'Bearer secret' },
			payload: {
				model: 'gpt-alias',
				input: 'use tool',
				tools: [{ type: 'function', name: 'Read', parameters: { type: 'object' } }]
			}
		});

		expect(response.statusCode).toBe(200);
		const responseBody = response.json<{ output: unknown[] }>();
		expect(responseBody.output).toEqual([
			expect.objectContaining({
				type: 'function_call',
				call_id: 'call_1',
				name: 'Read',
				arguments: '{"path":"a"}'
			})
		]);
		expect(proxyOpenAIRequestMock).toHaveBeenCalledWith(expect.objectContaining({ model: 'gpt-up', stream: true }), 'openai');
		await app.close();
	});

	it('routes Claude streaming responses as Responses SSE events', async () => {
		resolveForChatCompletionMock.mockReturnValueOnce(null);
		proxyRequestMock.mockResolvedValueOnce({
			response: sseResponse([
				'{"type":"message_start","message":{"usage":{"input_tokens":2,"output_tokens":0}}}',
				'{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}',
				'{"type":"message_delta","usage":{"output_tokens":1}}',
				'{"type":"message_stop"}'
			]),
			context: {
				startTime: Date.now(),
				model: 'claude-sonnet-4-6',
				source: 'claude',
				reverseToolMapping: {}
			}
		});

		const app = await withPlugin(responsesPlugin, { apiKey: 'secret' });
		const response = await app.inject({
			method: 'POST',
			url: '/v1/responses',
			headers: { 'x-api-key': 'secret' },
			payload: { model: 'claude-4.6-sonnet', input: 'hello', stream: true }
		});

		expect(response.statusCode).toBe(200);
		expect(response.headers['content-type']).toContain('text/event-stream');
		expect(response.body).toContain('event: response.output_text.delta');
		expect(response.body).toContain('event: response.completed');
		expect(response.body).not.toContain('[DONE]');
		expect(requestsRecordMock).toHaveBeenCalled();
		await app.close();
	});
});
