import { HeadersExtractor } from 'src/handlers/headers-extractor';
import { CompletionRequestTelemetry } from 'src/metrics';
import { CompletionErrorMapper, CompletionModelRouting, CompletionStreamingGateway } from 'src/orchestration/openai';
import {
	ResponsesNonStreamSynthesizer,
	ResponsesRequestNormalizer,
	ResponsesRequestValidationError,
	ResponsesRouteDecision,
	ResponsesStreamSynthesizer,
	restoreResponsesNamespaceValue,
	type ResponsesNamespaceToolMapping,
	type ResponsesRouteTarget
} from 'src/orchestration/responses';
import { apiKeyAuth } from 'src/plugins/auth';
import { proxyRequest } from 'src/proxy/anthropic-client';
import { proxyMiniMaxRequest } from 'src/proxy/minimax-client';
import { proxyOpenAIRequest } from 'src/proxy/proxy-client';
import { logger } from 'src/utils/logger';

import { OPENAI_MULTIMODAL_BODY_LIMIT_BYTES } from './openai-limits';

import type { ModelMappingConfig } from '@ungate/shared';
import type { FastifyPluginCallback, FastifyReply, FastifyRequest } from 'fastify';
import type { AnthropicResponse } from 'src/types';
import type { OpenAIChatRequest, OpenAIChatResponse, OpenAIResponsesRequest } from 'src/types/openai';
import type { ProxyResult, RequestContext } from 'src/types/proxy';

async function errorMessageFor(
	route: ResponsesRouteTarget,
	response: Response,
	context: RequestContext
): Promise<{ message: string; type: string; code?: string }> {
	if (route === 'claude') {
		const errorJson = await response.json().catch(() => ({ error: { message: `HTTP ${response.status}` } }));
		const payload = CompletionErrorMapper.claudeApiErrorPayload(errorJson, response.status);

		return { message: payload.message, type: payload.type ?? 'api_error', ...(payload.code && { code: payload.code }) };
	}

	if (route === 'minimax') {
		return { ...CompletionErrorMapper.miniMaxErrorPayload(response, context), type: 'api_error' };
	}

	return { message: await CompletionErrorMapper.openAiUpstreamErrorMessage(response), type: 'api_error' };
}

function recordError(reply: FastifyReply, context: RequestContext, message: string): void {
	const latencyMs = Date.now() - context.startTime;

	CompletionRequestTelemetry.recordAndApplyProxyHeaders(reply, latencyMs, {
		model: context.model,
		source: 'error',
		inputTokens: 0,
		outputTokens: 0,
		stream: false,
		latencyMs,
		error: message
	});
}

async function callUpstream(
	route: ResponsesRouteTarget,
	request: FastifyRequest,
	chatBody: OpenAIChatRequest,
	resolvedModel: ModelMappingConfig | null
): Promise<{ result: ProxyResult; upstreamBody: OpenAIChatRequest }> {
	if (route === 'minimax') {
		const upstreamBody = CompletionModelRouting.buildMiniMaxBody(chatBody, resolvedModel);

		return { result: await proxyMiniMaxRequest(upstreamBody), upstreamBody };
	}

	if (route === 'openai') {
		const upstreamBody = CompletionModelRouting.buildOpenAiUpstreamBody(chatBody, resolvedModel!);
		const proxyBody = chatBody.stream ? upstreamBody : { ...upstreamBody, stream: true };

		return { result: await proxyOpenAIRequest(proxyBody, 'openai'), upstreamBody: proxyBody };
	}

	HeadersExtractor.logRequestDetails(request.headers, request.url, request.method, 'OpenAI /v1/responses');
	const anthropicBody = CompletionModelRouting.toAnthropicRequest(chatBody, resolvedModel);
	const headers = HeadersExtractor.extractAnthropicHeaders(request.headers);

	return { result: await proxyRequest('/v1/messages', anthropicBody, headers), upstreamBody: chatBody };
}

function sendResponsesStream(
	reply: FastifyReply,
	route: ResponsesRouteTarget,
	response: Response,
	context: RequestContext,
	requestId: string,
	model: string,
	namespaceToolMapping: ResponsesNamespaceToolMapping
): FastifyReply {
	CompletionStreamingGateway.copyUpstreamHeaders(reply, response, true);
	reply.code(response.status);

	const { stream, headers } = ResponsesStreamSynthesizer.createResponseStream({
		source: route,
		response,
		requestId,
		model,
		context,
		namespaceToolMapping
	});

	for (const [key, value] of Object.entries(headers)) {
		reply.header(key, value);
	}

	return reply.send(stream);
}

async function sendResponsesJson(
	reply: FastifyReply,
	route: ResponsesRouteTarget,
	response: Response,
	context: RequestContext,
	requestId: string,
	model: string,
	namespaceToolMapping: ResponsesNamespaceToolMapping
): Promise<FastifyReply> {
	if (route === 'openai') {
		const synthesized = await ResponsesStreamSynthesizer.collectStreamResponse({
			source: route,
			response,
			requestId,
			model,
			context,
			streamRecord: false,
			namespaceToolMapping
		});

		CompletionRequestTelemetry.applyProxyHeaders(reply, Date.now() - context.startTime);

		return reply.send(synthesized);
	}

	if (route === 'claude') {
		const responseJson = await response.json();
		const anthropicJson = responseJson as AnthropicResponse;
		const synthesized = ResponsesNonStreamSynthesizer.synthesizeAnthropic(
			anthropicJson,
			model,
			requestId,
			context.reverseToolMapping
		);
		const latencyMs = Date.now() - context.startTime;

		CompletionRequestTelemetry.recordAndApplyProxyHeaders(reply, latencyMs, {
			model: context.model,
			source: context.source,
			inputTokens: context.inputTokens ?? synthesized.usage.input_tokens,
			outputTokens: context.outputTokens ?? synthesized.usage.output_tokens,
			stream: false,
			latencyMs
		});

		return reply.send(restoreResponsesNamespaceValue(synthesized, namespaceToolMapping));
	}

	let responseJson = context.bodyJson;
	if (responseJson === undefined) {
		responseJson = await response.json();
	}

	const json = responseJson as OpenAIChatResponse;
	const synthesized = ResponsesNonStreamSynthesizer.synthesize(json, model, requestId);
	const latencyMs = Date.now() - context.startTime;

	CompletionRequestTelemetry.recordAndApplyProxyHeaders(reply, latencyMs, {
		model: context.model,
		source: context.source,
		inputTokens: context.inputTokens ?? synthesized.usage.input_tokens,
		outputTokens: context.outputTokens ?? synthesized.usage.output_tokens,
		stream: false,
		latencyMs
	});

	return reply.send(restoreResponsesNamespaceValue(synthesized, namespaceToolMapping));
}

const plugin: FastifyPluginCallback = (app) => {
	const { config } = app;

	app.get('/v1/responses/health', { preHandler: apiKeyAuth(config) }, async (_request, reply) => {
		return reply.send({ status: 'ok', wire_api: 'responses' });
	});

	app.post(
		'/v1/responses',
		{ bodyLimit: OPENAI_MULTIMODAL_BODY_LIMIT_BYTES, preHandler: apiKeyAuth(config) },
		async (request, reply) => {
			const responsesBody = (request.body ?? {}) as OpenAIResponsesRequest;

			try {
				const { body: chatBody, resolvedModel, namespaceToolMapping } = ResponsesRequestNormalizer.toChatRequest(responsesBody);
				const route = ResponsesRouteDecision.decideRoute(resolvedModel, responsesBody.model);
				const requestId = Date.now().toString();
				const { result } = await callUpstream(route, request, chatBody, resolvedModel);
				const { response, context } = result;

				if (!response.ok) {
					const error = await errorMessageFor(route, response, context);

					CompletionStreamingGateway.copyRateLimitHeaders(reply, response);
					recordError(reply, context, error.message);

					return reply
						.code(response.status)
						.send(ResponsesNonStreamSynthesizer.errorResponse(error.message, error.type, error.code));
				}

				if (chatBody.stream) {
					return sendResponsesStream(reply, route, response, context, requestId, chatBody.model, namespaceToolMapping);
				}

				return sendResponsesJson(reply, route, response, context, requestId, chatBody.model, namespaceToolMapping);
			} catch (error) {
				if (error instanceof ResponsesRequestValidationError && error.code === 'empty_input') {
					logger.debug('Responses request validation rejected', {
						code: error.code,
						model: responsesBody.model,
						stream: responsesBody.stream ?? false,
						userAgent: request.headers['user-agent'],
						originator: request.headers.originator
					});
				} else if (error instanceof Error && error.message.includes('Responses input must be')) {
					logger.error(
						`Responses request handling error: ${error.message} \nPayload input: ${JSON.stringify(responsesBody.input)}`
					);
				} else {
					logger.error(`Responses request handling error: ${String(error)}`);
				}

				return reply
					.code(400)
					.send(
						ResponsesNonStreamSynthesizer.errorResponse(
							error instanceof Error ? error.message : String(error),
							'invalid_request_error'
						)
					);
			}
		}
	);
};

export default plugin;
