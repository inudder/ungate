import { ModelMappings } from 'src/database/model-mappings';
import { CodexInputUtils } from 'src/proxy/codex-input-utils';

import { flattenResponsesNamespaceTools } from './responses-namespace-tools';

import type { ModelMappingConfig } from '@ungate/shared';
import type {
	OpenAIChatRequest,
	OpenAIContentPart,
	OpenAIMessage,
	OpenAIResponseReasoningEffort,
	OpenAIResponsesFunctionTool,
	OpenAIResponsesRequest,
	OpenAITool
} from 'src/types/openai';

type ChatReasoningEffort = NonNullable<OpenAIChatRequest['reasoning']>['effort'];

const RESPONSES_COMPLETION_TOKEN_FLOOR = 8192;

export type ResponsesRequestValidationErrorCode = 'empty_input';

export class ResponsesRequestValidationError extends Error {
	readonly code: ResponsesRequestValidationErrorCode;

	constructor(code: ResponsesRequestValidationErrorCode, message: string) {
		super(message);
		this.name = 'ResponsesRequestValidationError';
		this.code = code;
	}
}

export interface ResponsesToChatRequestResult {
	body: OpenAIChatRequest;
	resolvedModel: ModelMappingConfig | null;
	namespaceToolMapping: ReturnType<typeof flattenResponsesNamespaceTools>['mapping'];
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function toText(value: unknown): string {
	if (typeof value === 'string') {
		return value;
	}

	if (typeof value === 'number' || typeof value === 'boolean') {
		return String(value);
	}

	if (value === null || value === undefined) {
		return '';
	}

	return JSON.stringify(value);
}

function normalizeReasoningEffort(effort: OpenAIResponseReasoningEffort | undefined): ChatReasoningEffort | undefined {
	if (!effort) {
		return undefined;
	}

	if (effort === 'minimal') {
		return 'low';
	}

	return effort as ChatReasoningEffort;
}

function normalizeMaxCompletionTokens(maxOutputTokens: number | undefined): number {
	if (maxOutputTokens === undefined || !Number.isFinite(maxOutputTokens) || maxOutputTokens <= 0) {
		return RESPONSES_COMPLETION_TOKEN_FLOOR;
	}

	return Math.max(Math.floor(maxOutputTokens), RESPONSES_COMPLETION_TOKEN_FLOOR);
}

function normalizeTool(tool: OpenAIResponsesFunctionTool | OpenAITool): OpenAITool {
	const record = tool as unknown as Record<string, unknown>;

	if (isRecord(record.function)) {
		const nested = record.function as OpenAITool['function'];

		return {
			type: 'function',
			function: {
				name: nested.name,
				description: nested.description,
				parameters: nested.parameters,
				strict: nested.strict
			}
		};
	}

	const responsesTool = tool as OpenAIResponsesFunctionTool;

	return {
		type: 'function',
		function: {
			name: responsesTool.name,
			description: responsesTool.description,
			parameters: responsesTool.parameters,
			strict: responsesTool.strict
		}
	};
}

function normalizeToolChoice(toolChoice: OpenAIResponsesRequest['tool_choice']): OpenAIChatRequest['tool_choice'] | undefined {
	if (!toolChoice) {
		return undefined;
	}

	if (typeof toolChoice === 'string') {
		return toolChoice;
	}

	const name = toolChoice.function?.name ?? toolChoice.name;
	if (!name) {
		return 'auto';
	}

	return { type: 'function', function: { name } };
}

function imagePartToChatPart(part: Record<string, unknown>): OpenAIContentPart | null {
	const type = part.type;
	if (type !== 'input_image' && type !== 'image_url') {
		return null;
	}

	const rawImageUrl = part.image_url ?? part.url;
	const detail = typeof part.detail === 'string' ? part.detail : undefined;

	if (typeof rawImageUrl === 'string' && rawImageUrl.length > 0) {
		return { type: 'image_url', image_url: { url: rawImageUrl, ...(detail && { detail: detail as 'auto' | 'low' | 'high' }) } };
	}

	if (isRecord(rawImageUrl) && typeof rawImageUrl.url === 'string' && rawImageUrl.url.length > 0) {
		const nestedDetail = typeof rawImageUrl.detail === 'string' ? rawImageUrl.detail : detail;

		return {
			type: 'image_url',
			image_url: {
				url: rawImageUrl.url,
				...(nestedDetail && { detail: nestedDetail as 'auto' | 'low' | 'high' })
			}
		};
	}

	return null;
}

function contentPartToChatText(part: Record<string, unknown>, role: OpenAIMessage['role']): string {
	const type = part.type;
	if (type === 'input_text' || type === 'output_text' || type === 'text') {
		return toText(part.text);
	}

	if (role === 'assistant' && type === 'refusal') {
		return toText(part.refusal);
	}

	throw new Error(`Unsupported Responses content part type: ${String(type)}`);
}

function contentToChatContent(content: unknown, role: OpenAIMessage['role']): string | OpenAIContentPart[] {
	if (typeof content === 'string') {
		return content;
	}

	if (!Array.isArray(content)) {
		return toText(content);
	}

	const textParts: string[] = [];
	const structuredParts: OpenAIContentPart[] = [];
	let sawImage = false;

	for (const part of content) {
		if (typeof part === 'string') {
			textParts.push(part);
			structuredParts.push({ type: 'text', text: part });
			continue;
		}

		if (!isRecord(part)) {
			continue;
		}

		const imagePart = role === 'user' ? imagePartToChatPart(part) : null;
		if (imagePart) {
			sawImage = true;
			structuredParts.push(imagePart);
			continue;
		}

		if (part.type === 'input_image') {
			const placeholder = '[Image input omitted: unsupported source]';
			textParts.push(placeholder);
			structuredParts.push({ type: 'text', text: placeholder });
			continue;
		}

		const text = contentPartToChatText(part, role);
		textParts.push(text);
		structuredParts.push({ type: 'text', text });
	}

	if (sawImage) {
		return structuredParts.filter((part) => part.type !== 'text' || Boolean(part.text));
	}

	return textParts.join('');
}

function messageItemToChatMessages(item: Record<string, unknown>): OpenAIMessage[] {
	const rawRole = typeof item.role === 'string' ? item.role : 'user';
	const role = rawRole === 'developer' ? 'system' : rawRole;

	if (role !== 'system' && role !== 'user' && role !== 'assistant') {
		throw new Error(`Unsupported Responses message role: ${rawRole}`);
	}

	const content = contentToChatContent(item.content, role);

	if (role === 'assistant') {
		return [{ role, content }];
	}

	return [{ role, content }];
}

function functionCallToToolCall(item: Record<string, unknown>): NonNullable<OpenAIMessage['tool_calls']>[number] {
	const callId = toText(item.call_id ?? item.id ?? `call_${Date.now()}`);
	const name = toText(item.name ?? 'unknown');
	const rawArguments = item.arguments ?? item.input ?? '{}';
	const callArguments = typeof rawArguments === 'string' ? rawArguments : JSON.stringify(rawArguments);

	return {
		id: callId,
		type: 'function',
		function: { name, arguments: callArguments }
	};
}

function functionOutputToChatMessage(item: Record<string, unknown>): OpenAIMessage {
	const callId = toText(item.call_id ?? item.id);

	if (!callId) {
		throw new Error('Responses function_call_output item is missing call_id');
	}

	const output = item.output ?? item.content ?? '';

	return {
		role: 'tool',
		tool_call_id: callId,
		content: typeof output === 'string' ? output : JSON.stringify(output)
	};
}

function mergeAssistantContent(current: OpenAIMessage['content'], incoming: OpenAIMessage['content']): OpenAIMessage['content'] {
	if (!current) {
		return incoming;
	}

	if (!incoming) {
		return current;
	}

	if (typeof current === 'string' && typeof incoming === 'string') {
		return `${current}\n${incoming}`;
	}

	const currentParts = typeof current === 'string' ? [{ type: 'text' as const, text: current }] : current;
	const incomingParts = typeof incoming === 'string' ? [{ type: 'text' as const, text: incoming }] : incoming;

	return [...currentParts, ...incomingParts];
}

function appendAssistantMessage(messages: OpenAIMessage[], incoming: OpenAIMessage): void {
	const previous = messages.at(-1);

	if (previous?.role !== 'assistant') {
		messages.push(incoming);

		return;
	}

	previous.content = mergeAssistantContent(previous.content, incoming.content);

	if (incoming.tool_calls?.length) {
		previous.tool_calls = [...(previous.tool_calls ?? []), ...incoming.tool_calls];
	}
}

export function itemsToChatMessages(items: Record<string, unknown>[], instructions?: string): OpenAIMessage[] {
	const messages: OpenAIMessage[] = [];

	if (instructions?.trim()) {
		messages.push({ role: 'system', content: instructions.trim() });
	}

	for (let index = 0; index < items.length; index += 1) {
		const item = items[index];
		const type = item.type;

		if (type === 'message') {
			for (const message of messageItemToChatMessages(item)) {
				if (message.role === 'assistant') {
					appendAssistantMessage(messages, message);
				} else {
					messages.push(message);
				}
			}
			continue;
		}

		if (type === 'function_call') {
			const toolCalls = [functionCallToToolCall(item)];

			while (items[index + 1]?.type === 'function_call') {
				index += 1;
				toolCalls.push(functionCallToToolCall(items[index]));
			}

			appendAssistantMessage(messages, { role: 'assistant', content: null, tool_calls: toolCalls });
			continue;
		}

		if (type === 'function_call_output') {
			messages.push(functionOutputToChatMessage(item));
			continue;
		}

		throw new Error(`Unsupported Responses input item type: ${String(type)}`);
	}

	if (messages.length === 0 || messages.every((message) => message.role === 'system')) {
		messages.push({ role: 'user', content: '.' });
	}

	return messages;
}

function inputToItems(input: OpenAIResponsesRequest['input']): Record<string, unknown>[] {
	if (typeof input === 'string') {
		if (!input.trim()) {
			throw new ResponsesRequestValidationError('empty_input', 'Responses input must not be empty');
		}

		return [{ type: 'message', role: 'user', content: [{ type: 'input_text', text: input }] }];
	}

	const expanded = CodexInputUtils.expandInput(input);
	if (!expanded) {
		throw new Error('Responses input must be a string or an array of supported input items');
	}

	return expanded;
}

function assertSupportedRequest(req: OpenAIResponsesRequest): void {
	if (!req.model?.trim()) {
		throw new Error('Responses request model is required');
	}
}

export class ResponsesRequestNormalizer {
	static toChatRequest(req: OpenAIResponsesRequest): ResponsesToChatRequestResult {
		assertSupportedRequest(req);
		const { request: flattenedRequest, mapping: namespaceToolMapping } = flattenResponsesNamespaceTools(req);

		const resolvedModel = ModelMappings.resolveForChatCompletion(flattenedRequest.model);
		const items = inputToItems(flattenedRequest.input);
		const reasoningEffort = normalizeReasoningEffort(flattenedRequest.reasoning?.effort);
		const body: OpenAIChatRequest = {
			model: flattenedRequest.model,
			messages: itemsToChatMessages(items, flattenedRequest.instructions),
			stream: flattenedRequest.stream ?? false,
			temperature: flattenedRequest.temperature,
			top_p: flattenedRequest.top_p,
			user: flattenedRequest.user,
			tools: flattenedRequest.tools?.map((tool) => normalizeTool(tool as OpenAIResponsesFunctionTool | OpenAITool)),
			tool_choice: normalizeToolChoice(flattenedRequest.tool_choice),
			max_completion_tokens: normalizeMaxCompletionTokens(flattenedRequest.max_output_tokens)
		};

		if (reasoningEffort) {
			body.reasoning_effort = reasoningEffort;
			body.reasoning = { effort: reasoningEffort };
		}

		if (flattenedRequest.parallel_tool_calls !== undefined) {
			(body as OpenAIChatRequest & { parallel_tool_calls?: boolean }).parallel_tool_calls = flattenedRequest.parallel_tool_calls;
		}

		return { body, resolvedModel, namespaceToolMapping };
	}
}
