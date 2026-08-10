import { afterEach, describe, expect, it, vi } from 'vitest';

import anthropicPlugin from 'src/routes/anthropic';
import { withPlugin } from '../test-harness';

const proxyRequestMock = vi.fn();
const telemetryRecordMock = vi.fn();

vi.mock('src/proxy/anthropic-client', () => ({
	proxyRequest: (...args: unknown[]) => proxyRequestMock(...args)
}));

vi.mock('src/metrics', () => ({
	CompletionRequestTelemetry: {
		record: (...args: unknown[]) => telemetryRecordMock(...args)
	}
}));

describe('routes-anthropic', () => {
	afterEach(() => {
		vi.clearAllMocks();
	});

	it('proxies stream body and headers', async () => {
		const upstreamBody = new ReadableStream<Uint8Array>({
			start(controller) {
				controller.enqueue(new TextEncoder().encode('ok'));
				controller.close();
			}
		});
		proxyRequestMock.mockResolvedValueOnce({
			response: new Response(upstreamBody, {
				status: 201,
				headers: {
					'content-type': 'text/plain',
					'content-encoding': 'gzip',
					'x-up': '1',
					'retry-after': '60',
					'anthropic-ratelimit-tokens-reset': '2026-07-29T17:00:00Z'
				}
			}),
			context: {
				model: 'm',
				source: 'claude',
				startTime: Date.now(),
				reverseToolMapping: {},
				inputTokens: 0,
				outputTokens: 0,
				cacheReadTokens: 0,
				cacheCreationTokens: 0
			}
		});

		const app = await withPlugin(anthropicPlugin, { apiKey: 'secret' });
		const response = await app.inject({
			method: 'POST',
			url: '/v1/messages',
			headers: { 'x-api-key': 'secret' },
			payload: { model: 'm', max_tokens: 10, messages: [] }
		});

		expect(response.statusCode).toBe(201);
		expect(response.headers['x-up']).toBe('1');
		expect(response.headers['retry-after']).toBe('60');
		expect(response.headers['anthropic-ratelimit-tokens-reset']).toBe('2026-07-29T17:00:00Z');
		expect(response.headers['content-encoding']).toBeUndefined();
		await app.close();
	});

	it('uses arrayBuffer fallback when body is missing', async () => {
		const noBodyResponse = new Response(null, { status: 202, headers: { 'x-up': 'x' } });
		proxyRequestMock.mockResolvedValueOnce({ response: noBodyResponse });

		const app = await withPlugin(anthropicPlugin, { apiKey: 'secret' });
		const response = await app.inject({
			method: 'POST',
			url: '/v1/messages',
			headers: { authorization: 'Bearer secret' },
			payload: { model: 'm', max_tokens: 10, messages: [] }
		});

		expect(response.statusCode).toBe(202);
		await app.close();
	});

	it('records cache usage for direct non-stream Messages requests', async () => {
		proxyRequestMock.mockResolvedValueOnce({
			response: new Response(
				JSON.stringify({
					id: 'msg_cache',
					type: 'message',
					content: [{ type: 'text', text: 'ok' }],
					usage: {
						input_tokens: 2,
						output_tokens: 1,
						cache_read_input_tokens: 5,
						cache_creation_input_tokens: 3
					}
				}),
				{ status: 200, headers: { 'content-type': 'application/json' } }
			),
			context: {
				model: 'claude-opus-5',
				source: 'claude',
				startTime: Date.now(),
				reverseToolMapping: {},
				inputTokens: 10,
				outputTokens: 1,
				cacheReadTokens: 5,
				cacheCreationTokens: 3
			}
		});

		const app = await withPlugin(anthropicPlugin, { apiKey: 'secret' });
		const response = await app.inject({
			method: 'POST',
			url: '/v1/messages',
			headers: { 'x-api-key': 'secret' },
			payload: { model: 'claude-opus-5', max_tokens: 10, messages: [] }
		});

		expect(response.statusCode).toBe(200);
		expect(telemetryRecordMock).toHaveBeenCalledWith(
			expect.objectContaining({ inputTokens: 10, outputTokens: 1, stream: false }),
			5,
			3
		);
		await app.close();
	});

	it('records cache usage while preserving direct Messages SSE', async () => {
		const sse = [
			'data: {"type":"message_start","message":{"usage":{"input_tokens":2,"output_tokens":0,"cache_read_input_tokens":5,"cache_creation_input_tokens":3}}}',
			'data: {"type":"message_delta","usage":{"output_tokens":1}}',
			'data: {"type":"message_stop"}'
		].join('\n\n') + '\n\n';
		proxyRequestMock.mockResolvedValueOnce({
			response: new Response(sse, { status: 200, headers: { 'content-type': 'text/event-stream' } }),
			context: {
				model: 'claude-opus-5',
				source: 'claude',
				startTime: Date.now(),
				reverseToolMapping: {},
				inputTokens: 0,
				outputTokens: 0,
				cacheReadTokens: 0,
				cacheCreationTokens: 0
			}
		});

		const app = await withPlugin(anthropicPlugin, { apiKey: 'secret' });
		const response = await app.inject({
			method: 'POST',
			url: '/v1/messages',
			headers: { 'x-api-key': 'secret' },
			payload: { model: 'claude-opus-5', max_tokens: 10, messages: [], stream: true }
		});

		expect(response.statusCode).toBe(200);
		expect(response.body).toContain('cache_read_input_tokens');
		expect(telemetryRecordMock).toHaveBeenCalledWith(
			expect.objectContaining({ inputTokens: 10, outputTokens: 1, stream: true }),
			5,
			3
		);
		await app.close();
	});

	it('returns 400 on thrown error', async () => {
		proxyRequestMock.mockRejectedValueOnce(new Error('upstream boom'));
		const app = await withPlugin(anthropicPlugin, { apiKey: 'secret' });
		const response = await app.inject({
			method: 'POST',
			url: '/v1/messages',
			headers: { authorization: 'Bearer secret' },
			payload: { model: 'm', max_tokens: 10, messages: [] }
		});

		expect(response.statusCode).toBe(400);
		expect(response.json().error.message).toContain('upstream boom');
		await app.close();
	});
});
