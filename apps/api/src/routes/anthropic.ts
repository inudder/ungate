import { logger } from 'src/utils/logger';

import { HeadersExtractor } from '../handlers/headers-extractor';
import { CompletionRequestTelemetry } from '../metrics';
import { apiKeyAuth } from '../plugins/auth';
import { proxyRequest } from '../proxy/anthropic-client';

import type { AnthropicRequest, AnthropicError } from '../types';
import type { AnthropicStreamEvent } from '../types/anthropic-stream';
import type { RequestContext } from '../types/proxy';
import type { FastifyPluginCallback } from 'fastify';

function instrumentAnthropicStream(stream: ReadableStream<Uint8Array>, context: RequestContext): ReadableStream<Uint8Array> {
	const decoder = new TextDecoder();
	let buffer = '';
	let inputTokens = 0;
	let outputTokens = 0;
	let cacheReadTokens = 0;
	let cacheCreationTokens = 0;
	let recorded = false;

	const record = () => {
		if (recorded) return;
		recorded = true;
		CompletionRequestTelemetry.record(
			{
				model: context.model,
				source: context.source,
				inputTokens,
				outputTokens,
				stream: true,
				latencyMs: Date.now() - context.startTime
			},
			cacheReadTokens,
			cacheCreationTokens
		);
	};

	const inspect = (text: string, flush = false) => {
		buffer += text;
		const lines = buffer.split('\n');
		buffer = flush ? '' : (lines.pop() ?? '');

		for (const line of lines) {
			if (!line.startsWith('data: ')) continue;
			try {
				const event = JSON.parse(line.slice(6)) as AnthropicStreamEvent;
				if (event.type === 'message_start') {
					const usage = event.message.usage;
					cacheReadTokens = usage.cache_read_input_tokens ?? 0;
					cacheCreationTokens = usage.cache_creation_input_tokens ?? 0;
					inputTokens = (usage.input_tokens ?? 0) + cacheReadTokens + cacheCreationTokens;
					outputTokens = usage.output_tokens ?? 0;
				} else if (event.type === 'message_delta') {
					outputTokens = event.usage.output_tokens ?? outputTokens;
				} else if (event.type === 'message_stop') {
					record();
				}
			} catch {
				// Preserve malformed or vendor-specific SSE events unchanged.
			}
		}
	};

	return stream.pipeThrough(
		new TransformStream<Uint8Array, Uint8Array>({
			transform(chunk, controller) {
				inspect(decoder.decode(chunk, { stream: true }));
				controller.enqueue(chunk);
			},
			flush() {
				inspect(decoder.decode(), true);
				record();
			}
		})
	);
}

const plugin: FastifyPluginCallback = (app) => {
	const { config } = app;

	app.post('/v1/messages', { preHandler: apiKeyAuth(config) }, async (request, reply) => {
		try {
			HeadersExtractor.logRequestDetails(request.headers, request.url, request.method, 'Anthropic /v1/messages');

			const body = request.body as AnthropicRequest;
			const headers = HeadersExtractor.extractAnthropicHeaders(request.headers);

			logger.log(`→ Model: "${body.model}" | ${body.stream ? 'stream' : 'sync'} | max_tokens=${body.max_tokens}`);

			const { response, context } = await proxyRequest('/v1/messages', body, headers);

			for (const [key, value] of response.headers.entries()) {
				if (key.toLowerCase() !== 'content-encoding') {
					reply.header(key, value);
				}
			}

			reply.code(response.status);

			if (response.body) {
				if (body.stream && response.ok) {
					return reply.send(instrumentAnthropicStream(response.body, context));
				}

				CompletionRequestTelemetry.record(
					{
						model: context.model,
						source: response.ok ? context.source : 'error',
						inputTokens: context.inputTokens ?? 0,
						outputTokens: context.outputTokens ?? 0,
						stream: false,
						latencyMs: Date.now() - context.startTime,
						...(!response.ok && { error: `HTTP ${response.status}` })
					},
					context.cacheReadTokens,
					context.cacheCreationTokens
				);

				return reply.send(response.body);
			}

			const fallbackBody = await response.arrayBuffer();

			return reply.send(fallbackBody);
		} catch (error) {
			logger.error(`Request handling error: ${String(error)}`);

			const errorBody: AnthropicError = {
				type: 'error',
				error: { type: 'invalid_request_error', message: String(error) }
			};

			return reply.code(400).send(errorBody);
		}
	});
};

export default plugin;
