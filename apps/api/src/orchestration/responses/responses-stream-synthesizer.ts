import { CompletionRequestTelemetry } from 'src/metrics';
import { logger } from 'src/utils/logger';

import { extractMiniMaxInlineToolCalls, inlineToolCallPendingSuffix } from './minimax-inline-tool-calls';
import { restoreResponsesNamespaceValue, type ResponsesNamespaceToolMapping } from './responses-namespace-tools';

import type { AnthropicStreamEvent } from 'src/types/anthropic-stream';
import type {
	OpenAIResponseOutputFunctionToolCall,
	OpenAIResponseOutputItem,
	OpenAIResponseOutputMessage,
	OpenAIResponsesResponse,
	OpenAIResponseStreamEvent,
	OpenAIResponseUsage,
	OpenAIStreamChunk
} from 'src/types/openai';
import type { RequestContext, StreamResult } from 'src/types/proxy';

export type ResponsesStreamSource = 'claude' | 'openai' | 'minimax';

interface CreateResponseStreamOptions {
	source: ResponsesStreamSource;
	response: Response;
	requestId: string;
	model: string;
	context: RequestContext;
	namespaceToolMapping?: ResponsesNamespaceToolMapping;
}

interface CollectResponseOptions extends CreateResponseStreamOptions {
	streamRecord?: boolean;
}

interface ParsedSse {
	payloads: string[];
	buffer: string;
}

interface ToolAccumulator {
	index: number;
	item: OpenAIResponseOutputFunctionToolCall;
	done: boolean;
}

type OutputStatus = OpenAIResponsesResponse['status'];

const THINK_OPEN = '<think>';
const THINK_CLOSE = '</think>';
const INLINE_TOOL_CALL_MARKERS = [']<]minimax[>[', '<tool_call>'];
// Keeps recovered calls from colliding with indices used by real tool_call deltas.
const INLINE_TOOL_CALL_INDEX_OFFSET = 10_000;

function findInlineToolCallStart(text: string): number {
	let earliest = -1;

	for (const marker of INLINE_TOOL_CALL_MARKERS) {
		const index = text.indexOf(marker);
		if (index >= 0 && (earliest === -1 || index < earliest)) {
			earliest = index;
		}
	}

	return earliest;
}

function nowSeconds(): number {
	return Math.floor(Date.now() / 1000);
}

function responseId(seed: string): string {
	const sanitized = seed.replace(/[^a-zA-Z0-9_-]/g, '');

	return seed.startsWith('resp_') ? seed : `resp_${sanitized.length > 0 ? sanitized : Date.now().toString(36)}`;
}

function eventId(prefix: string): string {
	return `${prefix}_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

function serializeEvent(event: Record<string, unknown>): string {
	return `event: ${String(event.type)}\ndata: ${JSON.stringify(event)}\n\n`;
}

function parseSse(buffer: string, text: string): ParsedSse {
	const next = buffer + text;
	const parts = next.split(/\r?\n\r?\n/);
	const tail = parts.pop() ?? '';
	const payloads: string[] = [];

	for (const part of parts) {
		const data = part
			.split(/\r?\n/)
			.filter((line) => line.startsWith('data:'))
			.map((line) => line.slice(5).trimStart())
			.join('\n')
			.trim();

		if (data) {
			payloads.push(data);
		}
	}

	return { payloads, buffer: tail };
}

function mapUsage(usage: unknown): OpenAIResponseUsage {
	const raw = usage && typeof usage === 'object' ? (usage as Record<string, unknown>) : {};
	const inputTokens = Number(raw.prompt_tokens ?? raw.input_tokens ?? 0);
	const outputTokens = Number(raw.completion_tokens ?? raw.output_tokens ?? 0);
	const totalTokens = Number(raw.total_tokens ?? inputTokens + outputTokens);

	return {
		input_tokens: Number.isFinite(inputTokens) ? inputTokens : 0,
		output_tokens: Number.isFinite(outputTokens) ? outputTokens : 0,
		total_tokens: Number.isFinite(totalTokens) ? totalTokens : 0
	};
}

function statusFromFinishReason(finishReason: string | null | undefined): {
	status: OutputStatus;
	incompleteReason?: string;
} {
	if (finishReason === 'length') {
		return { status: 'incomplete', incompleteReason: 'max_output_tokens' };
	}

	if (finishReason === 'content_filter') {
		return { status: 'incomplete', incompleteReason: 'content_filter' };
	}

	return { status: 'completed' };
}

function partialTagSuffix(text: string): string {
	for (let length = Math.min(text.length, THINK_CLOSE.length); length > 0; length--) {
		const suffix = text.slice(-length);
		if (THINK_OPEN.startsWith(suffix) || THINK_CLOSE.startsWith(suffix)) {
			return suffix;
		}
	}

	return '';
}

function parseMiniMaxText(
	text: string,
	state: 'content' | 'thinking',
	pendingTag: string
): {
	segments: { kind: 'content' | 'reasoning'; text: string }[];
	state: 'content' | 'thinking';
	pendingTag: string;
} {
	const segments: { kind: 'content' | 'reasoning'; text: string }[] = [];
	let buffer = pendingTag + text;
	let nextState = state;

	while (buffer.length > 0) {
		if (nextState === 'content') {
			const openIndex = buffer.indexOf(THINK_OPEN);

			if (openIndex === -1) {
				const pending = partialTagSuffix(buffer);
				const safeText = pending ? buffer.slice(0, -pending.length) : buffer;
				if (safeText) segments.push({ kind: 'content', text: safeText });

				return { segments, state: nextState, pendingTag: pending };
			}

			if (openIndex > 0) segments.push({ kind: 'content', text: buffer.slice(0, openIndex) });
			buffer = buffer.slice(openIndex + THINK_OPEN.length);
			nextState = 'thinking';
			continue;
		}

		const closeIndex = buffer.indexOf(THINK_CLOSE);
		if (closeIndex === -1) {
			const pending = partialTagSuffix(buffer);
			const safeText = pending ? buffer.slice(0, -pending.length) : buffer;
			if (safeText) segments.push({ kind: 'reasoning', text: safeText });

			return { segments, state: nextState, pendingTag: pending };
		}

		if (closeIndex > 0) segments.push({ kind: 'reasoning', text: buffer.slice(0, closeIndex) });
		buffer = buffer.slice(closeIndex + THINK_CLOSE.length);
		nextState = 'content';
	}

	return { segments, state: nextState, pendingTag: '' };
}

class ResponsesEventEmitter {
	private readonly responseId: string;
	private readonly createdAt = nowSeconds();
	private readonly model: string;
	private readonly reverseToolMapping: Record<string, string>;
	private readonly output: OpenAIResponseOutputItem[] = [];
	private readonly toolsByIndex = new Map<number, ToolAccumulator>();
	private started = false;
	private finalized = false;
	private messageItem: OpenAIResponseOutputMessage | null = null;
	private messageDone = false;
	private messageText = '';
	private finishReason: string | null = null;
	private incompleteReason: string | undefined;
	private usage: OpenAIResponseUsage = { input_tokens: 0, output_tokens: 0, total_tokens: 0 };
	private cacheReadTokens = 0;
	private cacheCreationTokens = 0;
	private minimaxState: 'content' | 'thinking' = 'content';
	private minimaxPendingTag = '';
	private minimaxTextBuffer = '';
	private minimaxLeakDetected = false;
	private minimaxRecoveredCalls = 0;

	constructor(requestId: string, model: string, reverseToolMapping: Record<string, string> = {}) {
		this.responseId = responseId(requestId);
		this.model = model;
		this.reverseToolMapping = reverseToolMapping;
	}

	start(): OpenAIResponseStreamEvent[] {
		if (this.started) {
			return [];
		}

		this.started = true;
		const response = this.response('in_progress');

		return [
			{ type: 'response.created', response },
			{ type: 'response.in_progress', response }
		];
	}

	textDelta(delta: string): OpenAIResponseStreamEvent[] {
		if (!delta) {
			return [];
		}

		const events = this.ensureMessage();
		this.messageText += delta;

		events.push({
			type: 'response.output_text.delta',
			response_id: this.responseId,
			item_id: this.messageItem!.id,
			output_index: this.output.indexOf(this.messageItem!),
			content_index: 0,
			delta
		});

		return events;
	}

	reasoningDelta(delta: string): Record<string, unknown>[] {
		if (!delta) {
			return [];
		}

		return [
			{
				type: 'response.reasoning_summary_text.delta',
				response_id: this.responseId,
				item_id: `rs_${this.responseId}`,
				output_index: 0,
				summary_index: 0,
				delta
			}
		];
	}

	minimaxTextDelta(delta: string): Record<string, unknown>[] {
		const parsed = parseMiniMaxText(delta, this.minimaxState, this.minimaxPendingTag);
		this.minimaxState = parsed.state;
		this.minimaxPendingTag = parsed.pendingTag;
		const events: Record<string, unknown>[] = [];

		// The MiniMax catalog disables reasoning summaries. Orphan summary deltas make Codex reject the entire SSE stream.
		for (const segment of parsed.segments) {
			if (segment.kind === 'content') {
				this.minimaxTextBuffer += segment.text;
			}
		}

		events.push(...this.drainMiniMaxBuffer());

		return events;
	}

	/**
	 * Emits buffered MiniMax text that cannot be part of a leaked tool-call
	 * marker. Once a marker is seen, text is held back until the stream ends so
	 * the whole block can be parsed into a real function call.
	 */
	private drainMiniMaxBuffer(): Record<string, unknown>[] {
		if (this.minimaxLeakDetected) {
			return [];
		}

		const markerIndex = findInlineToolCallStart(this.minimaxTextBuffer);

		if (markerIndex >= 0) {
			this.minimaxLeakDetected = true;
			const visible = this.minimaxTextBuffer.slice(0, markerIndex);
			this.minimaxTextBuffer = this.minimaxTextBuffer.slice(markerIndex);

			return visible ? this.textDelta(visible) : [];
		}

		const pending = inlineToolCallPendingSuffix(this.minimaxTextBuffer);
		const emittable = pending ? this.minimaxTextBuffer.slice(0, -pending.length) : this.minimaxTextBuffer;
		this.minimaxTextBuffer = pending;

		return emittable ? this.textDelta(emittable) : [];
	}

	/**
	 * Final MiniMax flush: recovers tool calls that the upstream emitted as plain
	 * text, so a turn that would otherwise end as prose keeps executing in Codex.
	 */
	flushMiniMax(): Record<string, unknown>[] {
		const events: Record<string, unknown>[] = [];

		if (this.minimaxPendingTag) {
			const pending = this.minimaxPendingTag;
			this.minimaxPendingTag = '';

			if (this.minimaxState !== 'thinking') {
				this.minimaxTextBuffer += pending;
			}
		}

		if (!this.minimaxTextBuffer) {
			return events;
		}

		const buffered = this.minimaxTextBuffer;
		this.minimaxTextBuffer = '';

		if (!this.minimaxLeakDetected) {
			return this.textDelta(buffered);
		}

		const extraction = extractMiniMaxInlineToolCalls(buffered);

		if (extraction.text) {
			events.push(...this.textDelta(extraction.text));
		}

		for (const call of extraction.toolCalls) {
			const index = INLINE_TOOL_CALL_INDEX_OFFSET + this.minimaxRecoveredCalls;
			this.minimaxRecoveredCalls += 1;
			events.push(...this.toolStart(index, `fc_inline_${eventId('mm')}`, call.name));
			events.push(...this.toolArgumentsDelta(index, call.arguments));
		}

		if (extraction.toolCalls.length > 0) {
			logger.log(`[MiniMax] recovered ${extraction.toolCalls.length} inline tool call(s) from assistant text`);
			this.finishReason = 'tool_calls';
		}

		return events;
	}

	toolStart(index: number, id: string | undefined, name: string | undefined): OpenAIResponseStreamEvent[] {
		const originalName = name ? (this.reverseToolMapping[name] ?? name) : undefined;
		const existing = this.toolsByIndex.get(index);
		if (existing) {
			if (originalName && existing.item.name === 'unknown') {
				existing.item.name = originalName;
			}

			return [];
		}

		const callId = id ?? eventId('call');
		const item: OpenAIResponseOutputFunctionToolCall = {
			id: id ?? eventId('fc'),
			type: 'function_call',
			call_id: callId,
			name: originalName ?? 'unknown',
			arguments: '',
			status: 'in_progress'
		};
		const outputIndex = this.output.length;
		this.output.push(item);
		this.toolsByIndex.set(index, { index: outputIndex, item, done: false });

		return [{ type: 'response.output_item.added', response_id: this.responseId, output_index: outputIndex, item }];
	}

	toolArgumentsDelta(index: number, delta: string): OpenAIResponseStreamEvent[] {
		if (!delta) {
			return [];
		}

		let events = this.toolStart(index, undefined, undefined);
		const tool = this.toolsByIndex.get(index)!;
		tool.item.arguments += delta;
		events = [
			...events,
			{
				type: 'response.function_call_arguments.delta',
				response_id: this.responseId,
				item_id: tool.item.id,
				output_index: tool.index,
				call_id: tool.item.call_id,
				delta
			}
		];

		return events;
	}

	toolDone(index: number): OpenAIResponseStreamEvent[] {
		const tool = this.toolsByIndex.get(index);
		if (!tool || tool.done) {
			return [];
		}

		tool.done = true;
		tool.item.status = this.finalStatus();

		return [
			{
				type: 'response.function_call_arguments.done',
				response_id: this.responseId,
				item_id: tool.item.id,
				output_index: tool.index,
				call_id: tool.item.call_id,
				name: tool.item.name,
				arguments: tool.item.arguments
			},
			{ type: 'response.output_item.done', response_id: this.responseId, output_index: tool.index, item: tool.item }
		];
	}

	setUsage(usage: unknown): void {
		this.usage = mapUsage(usage);
	}

	setAnthropicUsage(usage: {
		input_tokens?: number;
		output_tokens?: number;
		cache_read_input_tokens?: number;
		cache_creation_input_tokens?: number;
	}): void {
		this.cacheReadTokens = usage.cache_read_input_tokens ?? this.cacheReadTokens;
		this.cacheCreationTokens = usage.cache_creation_input_tokens ?? this.cacheCreationTokens;
		const inputTokens = (usage.input_tokens ?? this.usage.input_tokens) + this.cacheReadTokens + this.cacheCreationTokens;
		const outputTokens = usage.output_tokens ?? this.usage.output_tokens;

		this.usage = {
			input_tokens: inputTokens,
			output_tokens: outputTokens,
			total_tokens: inputTokens + outputTokens
		};
	}

	setFinishReason(finishReason: string | null | undefined): void {
		if (!finishReason) {
			return;
		}

		this.finishReason = finishReason;
		const mapped = statusFromFinishReason(finishReason);
		this.incompleteReason = mapped.incompleteReason;
	}

	finalize(fallbackFinishReason = 'stop'): OpenAIResponseStreamEvent[] {
		if (this.finalized) {
			return [];
		}

		this.finalized = true;
		if (!this.finishReason) {
			this.setFinishReason(fallbackFinishReason);
		}

		const events: OpenAIResponseStreamEvent[] = [];
		if (this.messageItem && !this.messageDone) {
			this.messageDone = true;
			this.messageItem.status = this.finalStatus();
			this.messageItem.content = [{ type: 'output_text', text: this.messageText, annotations: [] }];
			const outputIndex = this.output.indexOf(this.messageItem);
			const part = this.messageItem.content[0];

			events.push(
				{
					type: 'response.output_text.done',
					response_id: this.responseId,
					item_id: this.messageItem.id,
					output_index: outputIndex,
					content_index: 0,
					text: this.messageText
				},
				{
					type: 'response.content_part.done',
					response_id: this.responseId,
					item_id: this.messageItem.id,
					output_index: outputIndex,
					content_index: 0,
					part
				},
				{ type: 'response.output_item.done', response_id: this.responseId, output_index: outputIndex, item: this.messageItem }
			);
		}

		for (const [index] of this.toolsByIndex) {
			events.push(...this.toolDone(index));
		}

		const finalResponse = this.response(this.finalStatus());
		events.push({
			type: finalResponse.status === 'incomplete' ? 'response.incomplete' : 'response.completed',
			response: finalResponse
		});

		return events;
	}

	getFinalResponse(): OpenAIResponsesResponse {
		return this.response(this.finalStatus());
	}

	record(context: RequestContext, stream: boolean): void {
		CompletionRequestTelemetry.record(
			{
				model: context.model,
				source: context.source,
				inputTokens: this.usage.input_tokens,
				outputTokens: this.usage.output_tokens,
				stream,
				latencyMs: Date.now() - context.startTime
			},
			this.cacheReadTokens,
			this.cacheCreationTokens
		);
	}

	private ensureMessage(): OpenAIResponseStreamEvent[] {
		if (this.messageItem) {
			return [];
		}

		this.messageItem = {
			id: eventId('msg'),
			type: 'message',
			role: 'assistant',
			status: 'in_progress',
			content: []
		};
		const outputIndex = this.output.length;
		this.output.push(this.messageItem);
		const part: OpenAIResponseOutputMessage['content'][number] = { type: 'output_text', text: '', annotations: [] };

		return [
			{ type: 'response.output_item.added', response_id: this.responseId, output_index: outputIndex, item: this.messageItem },
			{
				type: 'response.content_part.added',
				response_id: this.responseId,
				item_id: this.messageItem.id,
				output_index: outputIndex,
				content_index: 0,
				part
			}
		];
	}

	private finalStatus(): 'completed' | 'incomplete' {
		return this.incompleteReason ? 'incomplete' : 'completed';
	}

	private response(status: OutputStatus): OpenAIResponsesResponse {
		return {
			id: this.responseId,
			object: 'response',
			created_at: this.createdAt,
			model: this.model,
			status,
			output: this.output,
			usage: this.usage,
			...(this.incompleteReason && { incomplete_details: { reason: this.incompleteReason } })
		};
	}
}

function processChatPayload(
	payload: string,
	emitter: ResponsesEventEmitter,
	source: ResponsesStreamSource
): Record<string, unknown>[] {
	if (payload === '[DONE]') {
		return [];
	}

	const chunk = JSON.parse(payload) as OpenAIStreamChunk & {
		usage?: Record<string, unknown>;
		choices?: (OpenAIStreamChunk['choices'][number] & { delta?: Record<string, unknown> })[];
	};
	const events: Record<string, unknown>[] = [];

	if (chunk.usage) {
		emitter.setUsage(chunk.usage);
	}

	for (const choice of chunk.choices ?? []) {
		emitter.setFinishReason(choice.finish_reason);
		const delta = choice.delta ?? {};

		for (const toolCall of delta.tool_calls ?? []) {
			const index = toolCall.index;
			events.push(...emitter.toolStart(index, toolCall.id, toolCall.function?.name));

			if (toolCall.function?.arguments !== undefined) {
				events.push(...emitter.toolArgumentsDelta(index, toolCall.function.arguments));
			}
		}

		if (source !== 'minimax' && typeof delta.reasoning_content === 'string') {
			events.push(...emitter.reasoningDelta(delta.reasoning_content));
		}

		if (typeof delta.content === 'string') {
			if (source === 'minimax') {
				events.push(...emitter.minimaxTextDelta(delta.content));
			} else {
				events.push(...emitter.textDelta(delta.content));
			}
		}
	}

	return events;
}

function processAnthropicPayload(payload: string, emitter: ResponsesEventEmitter): Record<string, unknown>[] {
	if (payload === '[DONE]') {
		return [];
	}

	const event = JSON.parse(payload) as AnthropicStreamEvent & {
		index?: number;
		message?: { usage?: Record<string, number> };
		delta?: { stop_reason?: string };
	};
	const events: Record<string, unknown>[] = [];

	if (event.type === 'message_start' && event.message?.usage) {
		emitter.setAnthropicUsage(event.message.usage);
	}

	if (event.type === 'content_block_start') {
		const block = event.content_block;

		if (block?.type === 'tool_use') {
			events.push(...emitter.toolStart(event.index ?? 0, block.id, block.name));
		}
	}

	if (event.type === 'content_block_delta') {
		if (event.delta?.type === 'text_delta') {
			events.push(...emitter.textDelta(event.delta.text));
		}

		if (event.delta?.type === 'input_json_delta') {
			events.push(...emitter.toolArgumentsDelta(event.index ?? 0, event.delta.partial_json ?? ''));
		}
	}

	if (event.type === 'content_block_stop') {
		events.push(...emitter.toolDone(event.index ?? 0));
	}

	if (event.type === 'message_delta') {
		if (event.usage) {
			emitter.setAnthropicUsage(event.usage);
		}

		emitter.setFinishReason(event.delta?.stop_reason === 'max_tokens' ? 'length' : event.delta?.stop_reason);
	}

	if (event.type === 'message_stop') {
		events.push(...emitter.finalize('stop'));
	}

	return events;
}

async function readStream(
	options: CreateResponseStreamOptions,
	onEvents: (events: Record<string, unknown>[]) => void
): Promise<ResponsesEventEmitter> {
	const reader = options.response.body?.getReader();
	if (!reader) {
		throw new Error('No response body');
	}

	const decoder = new TextDecoder();
	const emitter = new ResponsesEventEmitter(options.requestId, options.model, options.context.reverseToolMapping);
	let buffer = '';

	const processPayload = (payload: string): void => {
		try {
			const events =
				options.source === 'claude'
					? processAnthropicPayload(payload, emitter)
					: processChatPayload(payload, emitter, options.source);

			if (events.length > 0) {
				onEvents(events);
			}
		} catch (error) {
			logger.error(`Responses stream parse error: ${String(error)}`);
		}
	};

	onEvents(emitter.start());

	while (true) {
		const { done, value } = await reader.read();
		if (done) {
			break;
		}

		const parsed = parseSse(buffer, decoder.decode(value, { stream: true }));
		buffer = parsed.buffer;

		for (const payload of parsed.payloads) {
			processPayload(payload);
		}
	}

	// Some upstreams close immediately after writing the final SSE event and do
	// not send the blank line that normally dispatches it. Flush the decoder and
	// synthesize that delimiter so the final text, finish reason, or tool-call
	// arguments are not silently discarded before the response is finalized.
	const trailing = parseSse(buffer, `${decoder.decode()}\n\n`);
	for (const payload of trailing.payloads) {
		processPayload(payload);
	}

	if (options.source === 'minimax') {
		const pending = emitter.flushMiniMax();
		if (pending.length > 0) {
			onEvents(pending);
		}
	}

	const terminal = emitter.finalize('stop');
	if (terminal.length > 0) {
		onEvents(terminal);
	}

	reader.releaseLock();

	return emitter;
}

export class ResponsesStreamSynthesizer {
	static createResponseStream(options: CreateResponseStreamOptions): StreamResult {
		const headers: Record<string, string> = {
			'Content-Type': 'text/event-stream',
			'Cache-Control': 'no-cache',
			Connection: 'keep-alive',
			'X-Accel-Buffering': 'no',
			'x-request-id': `req_${options.requestId}`,
			'openai-processing-ms': '0',
			'openai-version': '2020-10-01'
		};

		const encoder = new TextEncoder();
		let cancelled = false;

		const stream = new ReadableStream({
			async start(controller) {
				try {
					const emitter = await readStream(options, (events) => {
						for (const event of events) {
							if (!cancelled) {
								const restoredEvent = options.namespaceToolMapping
									? restoreResponsesNamespaceValue(event, options.namespaceToolMapping)
									: event;
								controller.enqueue(encoder.encode(serializeEvent(restoredEvent)));
							}
						}
					});

					emitter.record(options.context, true);
				} catch (error) {
					logger.error(`Responses stream failed: ${String(error)}`);
					if (!cancelled) {
						controller.enqueue(
							encoder.encode(
								serializeEvent({
									type: 'response.error',
									error: { message: String(error), type: 'api_error' }
								})
							)
						);
					}
				} finally {
					if (!cancelled) {
						controller.close();
					}
				}
			},
			cancel() {
				cancelled = true;
			}
		});

		return { stream, headers };
	}

	static async collectStreamResponse(options: CollectResponseOptions): Promise<OpenAIResponsesResponse> {
		const emitter = await readStream(options, () => {});
		emitter.record(options.context, options.streamRecord ?? false);

		const response = emitter.getFinalResponse();

		return options.namespaceToolMapping ? restoreResponsesNamespaceValue(response, options.namespaceToolMapping) : response;
	}
}
