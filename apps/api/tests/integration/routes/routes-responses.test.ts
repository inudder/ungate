import { afterEach, describe, expect, it, vi } from 'vitest';

import responsesPlugin from 'src/routes/responses';
import { logger } from 'src/utils/logger';

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
		vi.restoreAllMocks();
		vi.clearAllMocks();
	});

	it('reports the authenticated Responses bridge health without calling an upstream provider', async () => {
		const app = await withPlugin(responsesPlugin, { apiKey: 'secret' });
		const response = await app.inject({
			method: 'GET',
			url: '/v1/responses/health',
			headers: { authorization: 'Bearer secret' }
		});

		expect(response.statusCode).toBe(200);
		expect(response.json()).toEqual({ status: 'ok', wire_api: 'responses' });
		expect(resolveForChatCompletionMock).not.toHaveBeenCalled();
		expect(proxyMiniMaxRequestMock).not.toHaveBeenCalled();
		expect(proxyOpenAIRequestMock).not.toHaveBeenCalled();
		expect(proxyRequestMock).not.toHaveBeenCalled();
		expect(requestsRecordMock).not.toHaveBeenCalled();
		await app.close();
	});

	it('protects the Responses bridge health endpoint with the configured API key', async () => {
		const app = await withPlugin(responsesPlugin, { apiKey: 'secret' });
		const response = await app.inject({
			method: 'GET',
			url: '/v1/responses/health',
			headers: { authorization: 'Bearer wrong-key' }
		});

		expect(response.statusCode).toBe(403);
		expect(response.json()).toEqual({
			type: 'error',
			error: { type: 'authentication_error', message: 'Unauthorized: Invalid API key' }
		});
		expect(resolveForChatCompletionMock).not.toHaveBeenCalled();
		await app.close();
	});

	it('returns the existing 400 contract for empty input and records only safe debug metadata', async () => {
		const debugSpy = vi.spyOn(logger, 'debug').mockImplementation(() => {});
		const errorSpy = vi.spyOn(logger, 'error').mockImplementation(() => {});
		const app = await withPlugin(responsesPlugin, { apiKey: 'secret' });
		const response = await app.inject({
			method: 'POST',
			url: '/v1/responses',
			headers: {
				authorization: 'Bearer secret',
				'user-agent': 'Codex Desktop/test',
				originator: 'codex_cli_rs'
			},
			payload: { model: 'minimax-alias', input: '', stream: true }
		});

		expect(response.statusCode).toBe(400);
		expect(response.json()).toEqual({
			error: { message: 'Responses input must not be empty', type: 'invalid_request_error' }
		});
		expect(debugSpy).toHaveBeenCalledWith('Responses request validation rejected', {
			code: 'empty_input',
			model: 'minimax-alias',
			stream: true,
			userAgent: 'Codex Desktop/test',
			originator: 'codex_cli_rs'
		});
		expect(errorSpy).not.toHaveBeenCalled();
		expect(proxyMiniMaxRequestMock).not.toHaveBeenCalled();
		expect(proxyOpenAIRequestMock).not.toHaveBeenCalled();
		expect(proxyRequestMock).not.toHaveBeenCalled();
		await app.close();
	});

	it('continues to log non-empty-input request failures as errors', async () => {
		const debugSpy = vi.spyOn(logger, 'debug').mockImplementation(() => {});
		const errorSpy = vi.spyOn(logger, 'error').mockImplementation(() => {});
		const app = await withPlugin(responsesPlugin, { apiKey: 'secret' });
		const response = await app.inject({
			method: 'POST',
			url: '/v1/responses',
			headers: { authorization: 'Bearer secret' },
			payload: { model: '', input: 'hello' }
		});

		expect(response.statusCode).toBe(400);
		expect(response.json()).toEqual({
			error: { message: 'Responses request model is required', type: 'invalid_request_error' }
		});
		expect(debugSpy).not.toHaveBeenCalled();
		expect(errorSpy).toHaveBeenCalledWith(
			'Responses request handling error: Error: Responses request model is required'
		);
		await app.close();
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
						content: expect.stringContaining('mcp__ungate_patch__apply_patch appears in the tool list')
					})
				])
			})
		);
		expect(requestsRecordMock).toHaveBeenCalled();
		await app.close();
	});

	it('ignores reasoning items in continuation input before routing tool calls', async () => {
		resolveForChatCompletionMock.mockReturnValueOnce({ provider: 'minimax', upstreamModel: 'mini-up' });
		proxyMiniMaxRequestMock.mockResolvedValueOnce({
			response: new Response(
				JSON.stringify({
					id: 'chatcmpl-continuation',
					object: 'chat.completion',
					created: 123,
					model: 'mini-up',
					choices: [{ index: 0, message: { role: 'assistant', content: 'continued' }, finish_reason: 'stop' }],
					usage: { prompt_tokens: 4, completion_tokens: 2, total_tokens: 6 }
				}),
				{ status: 200, headers: { 'content-type': 'application/json' } }
			),
			context: {
				startTime: Date.now(),
				model: 'mini-up',
				source: 'minimax',
				reverseToolMapping: {},
				inputTokens: 4,
				outputTokens: 2
			}
		});

		const app = await withPlugin(responsesPlugin, { apiKey: 'secret' });
		const response = await app.inject({
			method: 'POST',
			url: '/v1/responses',
			headers: { authorization: 'Bearer secret' },
			payload: {
				model: 'minimax-alias',
				input: [
					{ type: 'reasoning', id: 'rs_1', summary: [{ type: 'summary_text', text: 'private' }] },
					{ type: 'message', role: 'user', content: [{ type: 'input_text', text: 'continue' }] },
					{ type: 'function_call', call_id: 'call_1', name: 'Read', arguments: '{}' },
					{ type: 'reasoning', id: 'rs_2', summary: [{ type: 'summary_text', text: 'private again' }] },
					{ type: 'function_call_output', call_id: 'call_1', output: 'done' }
				]
			}
		});

		expect(response.statusCode).toBe(200);
		expect(response.json()).toMatchObject({ status: 'completed', model: 'minimax-alias' });
		expect(proxyMiniMaxRequestMock).toHaveBeenCalledWith(
			expect.objectContaining({
				messages: [
					{ role: 'user', content: 'continue' },
					{
						role: 'assistant',
						content: null,
						tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'Read', arguments: '{}' } }]
					},
					{ role: 'tool', tool_call_id: 'call_1', content: 'done' }
				]
			})
		);
		await app.close();
	});

	it('flattens MCP namespace tools for MiniMax and restores the namespace in streaming tool calls', async () => {
		resolveForChatCompletionMock.mockReturnValueOnce({ provider: 'minimax', upstreamModel: 'mini-up' });
		proxyMiniMaxRequestMock.mockResolvedValueOnce({
			response: sseResponse([
				JSON.stringify({
					choices: [
						{
							delta: {
								tool_calls: [
									{
										index: 0,
										id: 'call_patch',
										type: 'function',
										function: {
											name: 'mcp__ungate_patch__apply_patch',
											arguments: '{"working_directory":"J:\\\\Dev\\\\project","patch":"*** Begin Patch"}'
										}
									}
								]
							},
							finish_reason: 'tool_calls'
						}
					],
					usage: { prompt_tokens: 1, completion_tokens: 2, total_tokens: 3 }
				})
			]),
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
				input: 'apply it',
				stream: true,
				tools: [
					{
						type: 'namespace',
						name: 'mcp__ungate_patch',
						tools: [
							{
								type: 'function',
								name: 'apply_patch',
								description: 'Apply a source patch',
								inputSchema: {
									type: 'object',
									properties: { working_directory: { type: 'string' }, patch: { type: 'string' } },
									required: ['working_directory', 'patch']
								}
							}
						]
					}
				]
			}
		});

		expect(response.statusCode).toBe(200);
		expect(proxyMiniMaxRequestMock).toHaveBeenCalledWith(
			expect.objectContaining({
				tools: [
					expect.objectContaining({
						function: expect.objectContaining({
							name: 'mcp__ungate_patch__apply_patch',
							parameters: expect.objectContaining({ required: ['working_directory', 'patch'] })
						})
					})
				]
			})
		);
		expect(response.body).toContain('"name":"apply_patch"');
		expect(response.body).toContain('"namespace":"mcp__ungate_patch"');
		expect(response.body).toContain('response.function_call_arguments.done');
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
				'{"type":"message_start","message":{"usage":{"input_tokens":2,"output_tokens":0,"cache_read_input_tokens":5,"cache_creation_input_tokens":3}}}',
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
		expect(response.body).toContain('"input_tokens":10');
		expect(response.body).toContain('"cached_tokens":5');
		expect(response.body).toContain('"cache_creation_tokens":3');
		expect(response.body).not.toContain('[DONE]');
		expect(requestsRecordMock).toHaveBeenCalledWith(
			expect.objectContaining({ inputTokens: 10, outputTokens: 1 }),
			5,
			3
		);
		await app.close();
	});

	it('returns Claude usage-window quota details and reset headers from Responses', async () => {
		resolveForChatCompletionMock.mockReturnValueOnce(null);
		proxyRequestMock.mockResolvedValueOnce({
			response: new Response(
				JSON.stringify({ error: { message: "You've reached your usage limit", type: 'rate_limit_error' } }),
				{
					status: 429,
					headers: {
						'content-type': 'application/json',
						'retry-after': '3600',
						'x-ratelimit-requests-reset': '2026-07-29T17:00:00Z'
					}
				}
			),
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
			payload: { model: 'claude-4.6-sonnet', input: 'hello' }
		});

		expect(response.statusCode).toBe(429);
		expect(response.json()).toEqual({
			error: {
				message: "Quota exceeded: You've reached your usage limit",
				type: 'rate_limit_error',
				code: 'insufficient_quota'
			}
		});
		expect(response.headers['retry-after']).toBe('3600');
		expect(response.headers['x-ratelimit-requests-reset']).toBe('2026-07-29T17:00:00Z');
		await app.close();
	});

	it('carries MCP namespace tools through the Claude route and restores the tool call for Codex', async () => {
		resolveForChatCompletionMock.mockReturnValueOnce({
			provider: 'claude',
			upstreamModel: 'claude-opus-4-8',
			reasoningBudget: 'high'
		});
		proxyRequestMock.mockResolvedValueOnce({
			response: new Response(
				JSON.stringify({
					id: 'msg_patch',
					model: 'claude-opus-4-8',
					content: [
						{
							type: 'tool_use',
							id: 'call_patch',
							name: 'Edit',
							input: { working_directory: 'J:\\Dev\\project', patch: '*** Begin Patch' }
						}
					],
					stop_reason: 'tool_use',
					usage: {
						input_tokens: 2,
						output_tokens: 3,
						cache_read_input_tokens: 5,
						cache_creation_input_tokens: 3
					}
				}),
				{ status: 200, headers: { 'content-type': 'application/json' } }
			),
			context: {
				startTime: Date.now(),
				model: 'claude-opus-4-8',
				source: 'claude',
				reverseToolMapping: { Edit: 'mcp__ungate_patch__apply_patch' },
				inputTokens: 10,
				outputTokens: 3,
				cacheReadTokens: 5,
				cacheCreationTokens: 3
			}
		});

		const app = await withPlugin(responsesPlugin, { apiKey: 'secret' });
		const response = await app.inject({
			method: 'POST',
			url: '/v1/responses',
			headers: { 'x-api-key': 'secret' },
			payload: {
				model: 'ungate-opus-4-8',
				input: 'apply it',
				tools: [
					{
						type: 'namespace',
						name: 'mcp__ungate_patch',
						tools: [
							{
								type: 'function',
								name: 'apply_patch',
								description: 'Apply a source patch',
								inputSchema: {
									type: 'object',
									properties: { working_directory: { type: 'string' }, patch: { type: 'string' } },
									required: ['working_directory', 'patch']
								}
							}
						]
					}
				]
			}
		});

		expect(response.statusCode).toBe(200);
		expect(proxyRequestMock).toHaveBeenCalledWith(
			'/v1/messages',
			expect.objectContaining({
				model: 'claude-opus-4-8',
				tools: [
					expect.objectContaining({
						name: 'mcp__ungate_patch__apply_patch',
						input_schema: expect.objectContaining({ required: ['working_directory', 'patch'] })
					})
				]
			}),
			expect.any(Object)
		);
		expect(response.json()).toMatchObject({
			usage: {
				input_tokens: 10,
				input_tokens_details: { cached_tokens: 5, cache_creation_tokens: 3 }
			},
			output: [
				{
					type: 'function_call',
					name: 'apply_patch',
					namespace: 'mcp__ungate_patch',
					call_id: 'call_patch'
				}
			]
		});
		await app.close();
	});
});
