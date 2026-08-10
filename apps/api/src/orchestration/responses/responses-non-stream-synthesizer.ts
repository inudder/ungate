import type { AnthropicResponse, ContentBlock } from 'src/types';
import type {
	OpenAIChatResponse,
	OpenAIResponsesErrorResponse,
	OpenAIResponsesResponse,
	OpenAIResponseOutputFunctionToolCall,
	OpenAIResponseOutputItem,
	OpenAIResponseOutputMessage,
	OpenAIResponseUsage
} from 'src/types/openai';

type ChatFinishReason = OpenAIChatResponse['choices'][number]['finish_reason'];

function nowSeconds(): number {
	return Math.floor(Date.now() / 1000);
}

function responseId(seed?: string): string {
	if (seed?.startsWith('resp_')) {
		return seed;
	}

	const sanitized = seed?.replace(/[^a-zA-Z0-9_-]/g, '') ?? '';
	const suffix = sanitized.length > 0 ? sanitized : `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`;

	return `resp_${suffix}`;
}

function itemId(prefix: string): string {
	return `${prefix}_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

function mapUsage(usage: unknown): OpenAIResponseUsage {
	const raw = usage && typeof usage === 'object' ? (usage as Record<string, unknown>) : {};
	const cacheReadTokens = Number(raw.prompt_cache_hit_tokens ?? raw.cache_read_input_tokens ?? 0);
	const cacheCreationTokens = Number(raw.prompt_cache_miss_tokens ?? raw.cache_creation_input_tokens ?? 0);
	const regularInputTokens = Number(raw.prompt_tokens ?? raw.input_tokens ?? 0);
	const inputTokens =
		raw.prompt_tokens === undefined ? regularInputTokens + cacheReadTokens + cacheCreationTokens : regularInputTokens;
	const outputTokens = Number(raw.completion_tokens ?? raw.output_tokens ?? 0);
	const totalTokens = Number(raw.total_tokens ?? inputTokens + outputTokens);

	return {
		input_tokens: Number.isFinite(inputTokens) ? inputTokens : 0,
		output_tokens: Number.isFinite(outputTokens) ? outputTokens : 0,
		total_tokens: Number.isFinite(totalTokens) ? totalTokens : 0,
		...(cacheReadTokens > 0 || cacheCreationTokens > 0
			? {
					input_tokens_details: {
						cached_tokens: Number.isFinite(cacheReadTokens) ? cacheReadTokens : 0,
						cache_creation_tokens: Number.isFinite(cacheCreationTokens) ? cacheCreationTokens : 0
					}
				}
			: {})
	};
}

function finishToStatus(finish: ChatFinishReason | undefined): {
	status: OpenAIResponsesResponse['status'];
	incomplete_details?: { reason: string };
} {
	if (finish === 'length') {
		return { status: 'incomplete', incomplete_details: { reason: 'max_output_tokens' } };
	}

	if (finish === 'content_filter') {
		return { status: 'incomplete', incomplete_details: { reason: 'content_filter' } };
	}

	return { status: 'completed' };
}

function textItem(text: string): OpenAIResponseOutputMessage {
	return {
		id: itemId('msg'),
		type: 'message',
		role: 'assistant',
		status: 'completed',
		content: [{ type: 'output_text', text, annotations: [] }]
	};
}

function toolCallItem(
	toolCall: NonNullable<OpenAIChatResponse['choices'][number]['message']['tool_calls']>[number]
): OpenAIResponseOutputFunctionToolCall {
	return {
		id: toolCall.id ?? itemId('fc'),
		type: 'function_call',
		call_id: toolCall.id ?? itemId('call'),
		name: toolCall.function?.name ?? 'unknown',
		arguments: toolCall.function?.arguments ?? '{}',
		status: 'completed'
	};
}

function chatOutputItems(chatResponse: OpenAIChatResponse): OpenAIResponseOutputItem[] {
	const output: OpenAIResponseOutputItem[] = [];

	for (const choice of chatResponse.choices ?? []) {
		const message = choice.message;

		if (typeof message?.content === 'string' && message.content.length > 0) {
			output.push(textItem(message.content));
		}

		for (const toolCall of message?.tool_calls ?? []) {
			output.push(toolCallItem(toolCall));
		}
	}

	return output;
}

function anthropicStopToStatus(stopReason: AnthropicResponse['stop_reason']): {
	status: OpenAIResponsesResponse['status'];
	incomplete_details?: { reason: string };
} {
	if (stopReason === 'max_tokens') {
		return { status: 'incomplete', incomplete_details: { reason: 'max_output_tokens' } };
	}

	return { status: 'completed' };
}

function anthropicToolItem(
	block: ContentBlock,
	reverseToolMapping: Record<string, string>
): OpenAIResponseOutputFunctionToolCall {
	const callId = block.id ?? itemId('call');
	const args = typeof block.input === 'string' ? block.input : JSON.stringify(block.input ?? {});
	const name = block.name ? (reverseToolMapping[block.name] ?? block.name) : 'unknown';

	return {
		id: block.id ?? itemId('fc'),
		type: 'function_call',
		call_id: callId,
		name,
		arguments: args,
		status: 'completed'
	};
}

function anthropicOutputItems(
	response: AnthropicResponse,
	reverseToolMapping: Record<string, string>
): OpenAIResponseOutputItem[] {
	const output: OpenAIResponseOutputItem[] = [];
	let text = '';

	for (const block of response.content ?? []) {
		if (block.type === 'text') {
			text += block.text ?? '';
			continue;
		}

		if (block.type === 'tool_use') {
			if (text.length > 0) {
				output.push(textItem(text));
				text = '';
			}

			output.push(anthropicToolItem(block, reverseToolMapping));
		}
	}

	if (text.length > 0) {
		output.push(textItem(text));
	}

	return output;
}

export class ResponsesNonStreamSynthesizer {
	static synthesize(chatResponse: OpenAIChatResponse, model: string, requestId?: string): OpenAIResponsesResponse {
		const finish = chatResponse.choices?.find((choice) => choice.finish_reason)?.finish_reason;
		const status = finishToStatus(finish);

		return {
			id: responseId(requestId),
			object: 'response',
			created_at: chatResponse.created ?? nowSeconds(),
			model,
			status: status.status,
			output: chatOutputItems(chatResponse),
			usage: mapUsage(chatResponse.usage),
			...(status.incomplete_details && { incomplete_details: status.incomplete_details })
		};
	}

	static synthesizeAnthropic(
		anthropicResponse: AnthropicResponse,
		model: string,
		requestId?: string,
		reverseToolMapping: Record<string, string> = {}
	): OpenAIResponsesResponse {
		const status = anthropicStopToStatus(anthropicResponse.stop_reason);

		return {
			id: responseId(requestId ?? anthropicResponse.id),
			object: 'response',
			created_at: nowSeconds(),
			model,
			status: status.status,
			output: anthropicOutputItems(anthropicResponse, reverseToolMapping),
			usage: mapUsage(anthropicResponse.usage),
			...(status.incomplete_details && { incomplete_details: status.incomplete_details })
		};
	}

	static errorResponse(message: string, type = 'api_error', code?: string): OpenAIResponsesErrorResponse {
		return {
			error: {
				message,
				type,
				...(code && { code })
			}
		};
	}
}
