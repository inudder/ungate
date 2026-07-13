import { logger } from 'src/utils/logger';

import { getProvider } from '../auth';
import { config } from '../config';
import { ProviderSettings } from '../database/provider-settings';

import type { OpenAIChatRequest, OpenAIContentPart, OpenAIMessage } from '../types/openai';
import type { RequestContext } from '../types/proxy';

interface MiniMaxResponseBody {
	base_resp?: {
		status_code?: number | string;
		status_msg?: string;
	};
	usage?: {
		input_tokens?: number;
		output_tokens?: number;
		prompt_tokens?: number;
		completion_tokens?: number;
	};
}

interface MiniMaxResponseNormalization {
	response: Response;
	bodyJson?: unknown;
	inputTokens?: number;
	outputTokens?: number;
}

function getMiniMaxReasoning(body: OpenAIChatRequest):
	| {
			clientEffort: string;
			upstreamType: 'disabled' | 'adaptive';
			thinking: { type: 'disabled' | 'adaptive' };
	  }
	| undefined {
	const clientEffort = body.reasoning?.effort ?? body.reasoning_effort;

	if (!clientEffort) {
		return undefined;
	}

	if (clientEffort === 'none') {
		return {
			clientEffort,
			upstreamType: 'disabled',
			thinking: { type: 'disabled' }
		};
	}

	return {
		clientEffort,
		upstreamType: 'adaptive',
		thinking: { type: 'adaptive' }
	};
}

function normalizeMiniMaxContent(content: OpenAIMessage['content']): OpenAIMessage['content'] {
	if (!Array.isArray(content)) {
		return content;
	}

	return content.map((part) => {
		if (part.type !== 'image_url' || !part.image_url) {
			return part;
		}

		const detail = part.image_url.detail === 'auto' ? 'default' : part.image_url.detail;
		const imageUrl: { url: string; detail?: 'low' | 'default' | 'high' } = { url: part.image_url.url };

		if (detail) {
			imageUrl.detail = detail;
		}

		return { type: 'image_url', image_url: imageUrl } as OpenAIContentPart;
	});
}

function normalizeMiniMaxMessages(messages: OpenAIMessage[]): Record<string, unknown>[] {
	return messages.map((message) => ({
		...message,
		role: message.role === 'developer' ? 'system' : message.role,
		content: normalizeMiniMaxContent(message.content)
	}));
}

function jsonContentType(response: Response): boolean {
	return response.headers.get('content-type')?.toLowerCase().includes('application/json') ?? false;
}

function miniMaxErrorBody(body: MiniMaxResponseBody): { code: string; message: string } | null {
	const statusCode = body.base_resp?.status_code;

	if (statusCode === undefined || String(statusCode) === '0') {
		return null;
	}

	const code = String(statusCode);
	const upstreamStatusMessage = body.base_resp?.status_msg?.trim();
	const statusMessage = upstreamStatusMessage?.length ? upstreamStatusMessage : 'MiniMax rejected the request';

	return { code, message: `MiniMax error ${code}: ${statusMessage}` };
}

export async function normalizeMiniMaxUpstreamResponse(
	response: Response,
	stream: boolean
): Promise<MiniMaxResponseNormalization> {
	if (stream && !jsonContentType(response)) {
		return { response };
	}

	try {
		const responseClone = response.clone();
		const bodyJson: MiniMaxResponseBody = await responseClone.json();
		const error = miniMaxErrorBody(bodyJson);

		if (error) {
			const errorBody = { error: { message: error.message, type: 'api_error', code: error.code } };

			logger.error(`MiniMax upstream error ${error.code}: ${error.message}`);

			return {
				response: new Response(JSON.stringify(errorBody), {
					status: 502,
					headers: { 'Content-Type': 'application/json' }
				}),
				bodyJson: errorBody
			};
		}

		if (!stream) {
			return {
				response,
				bodyJson,
				inputTokens: bodyJson.usage?.prompt_tokens ?? bodyJson.usage?.input_tokens,
				outputTokens: bodyJson.usage?.completion_tokens ?? bodyJson.usage?.output_tokens
			};
		}
	} catch {
		// A streaming response is normally SSE; non-JSON error responses are handled by the route.
	}

	return { response };
}

export function buildMiniMaxRequestBody(body: OpenAIChatRequest): Record<string, unknown> {
	const tools =
		body.tools?.filter((tool) => {
			const parameters = tool.function?.parameters;

			return Boolean(tool.function?.name?.trim() && parameters && typeof parameters === 'object' && !Array.isArray(parameters));
		}) ?? [];
	const hasTools = tools.length > 0;
	const thinking = getMiniMaxReasoning(body)?.thinking;

	return {
		model: body.model,
		messages: normalizeMiniMaxMessages(body.messages),
		stream: body.stream ?? false,
		...(body.stream && {
			stream_options: {
				include_usage: true
			}
		}),
		max_completion_tokens: body.max_completion_tokens ?? body.max_tokens ?? 4096,
		temperature: body.temperature,
		top_p: body.top_p,
		...(thinking && { thinking }),
		...(hasTools && { tools }),
		...(hasTools &&
			body.tool_choice && {
				tool_choice: typeof body.tool_choice === 'string' ? body.tool_choice : 'auto'
			})
	};
}

export async function proxyMiniMaxRequest(body: OpenAIChatRequest): Promise<{
	response: Response;
	context: RequestContext;
}> {
	const creds = ProviderSettings.get('minimax');
	const minimaxUrl = (creds?.baseUrl ?? config.minimax.baseUrlGlobal).replace(/\/+$/, '');
	const provider = getProvider('minimax');
	const authHeader = await provider.getAuthHeader();

	if (!authHeader) {
		const noAuthResponse = new Response(
			JSON.stringify({ error: { message: 'No MiniMax API key configured', type: 'authentication_error' } }),
			{
				status: 401,
				headers: { 'Content-Type': 'application/json' }
			}
		);

		return {
			response: noAuthResponse,
			context: {
				model: body.model,
				startTime: Date.now(),
				source: 'minimax',
				reverseToolMapping: {},
				bodyJson: { error: { message: 'No MiniMax API key configured', type: 'authentication_error' } }
			}
		};
	}

	const minimaxBody = buildMiniMaxRequestBody(body);
	const reasoning = getMiniMaxReasoning(body);

	logger.log(
		reasoning
			? `[MiniMax] thinking: client=${reasoning.clientEffort}, upstream=${reasoning.upstreamType}`
			: '[MiniMax] thinking: not provided'
	);

	const startTime = Date.now();

	try {
		const response = await fetch(`${minimaxUrl}/v1/chat/completions`, {
			method: 'POST',
			headers: {
				Authorization: authHeader,
				'Content-Type': 'application/json'
			},
			body: JSON.stringify(minimaxBody)
		});

		logger.log(`✓ MiniMax request → ${response.status}`);

		const normalized = await normalizeMiniMaxUpstreamResponse(response, body.stream ?? false);

		return {
			response: normalized.response,
			context: {
				model: body.model,
				startTime,
				source: 'minimax' as const,
				reverseToolMapping: {},
				inputTokens: normalized.inputTokens,
				outputTokens: normalized.outputTokens,
				bodyJson: normalized.bodyJson
			}
		};
	} catch (error) {
		logger.error(`MiniMax request failed: ${String(error)}`);

		return {
			response: new Response(JSON.stringify({ error: { message: String(error), type: 'api_error' } }), {
				status: 500,
				headers: { 'Content-Type': 'application/json' }
			}),
			context: {
				model: body.model,
				startTime,
				source: 'minimax' as const,
				reverseToolMapping: {},
				inputTokens: undefined,
				outputTokens: undefined
			}
		};
	}
}
