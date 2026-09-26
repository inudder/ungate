import { Transform } from 'node:stream';
import { StringDecoder } from 'node:string_decoder';

import { restoreMimoResponsesValue } from './mimo-responses-namespace.mjs';

const FUNCTION_PATTERN = /<tool_call>\s*<function=([^>\s]+)>\s*([\s\S]*?)<\/function>\s*<\/tool_call>/g;
const NAMED_PARAMETER_PATTERN = /^\s*<parameter(?:=([^>\r\n]*))?>([\s\S]*?)<\/parameter>\s*$/;
const RAW_PARAMETER_PATTERN = /^\s*<parameter=([\s\S]*?)<\/parameter>\s*$/;
const MISSING_OPENING_PARAMETER_PATTERN = /^([\s\S]*?)<\/parameter>\s*$/;
const POSSIBLE_TOOL_MARKUP = /<\/?(?:tool_call|function|parameter)(?:\s|=|>)/i;

function parseSseFrame(raw) {
	const lines = raw.split(/\r?\n/);
	const dataLines = [];
	let eventName = null;
	for (const line of lines) {
		if (line.startsWith('event:')) {
			eventName = line.slice(6).trim();
		} else if (line.startsWith('data:')) {
			dataLines.push(line.slice(5).startsWith(' ') ? line.slice(6) : line.slice(5));
		}
	}
	if (dataLines.length === 0) {
		return { raw, eventName, dataText: null, data: null };
	}
	const dataText = dataLines.join('\n');
	if (dataText === '[DONE]') {
		return { raw, eventName, dataText, data: null, doneToken: true };
	}
	try {
		return { raw, eventName, dataText, data: JSON.parse(dataText) };
	} catch {
		return { raw, eventName, dataText, data: null, invalidJson: true };
	}
}

function encodeSse(eventName, data) {
	return `event: ${eventName}\ndata: ${JSON.stringify(data)}\n\n`;
}

function responseEvent(type, responseId, data = {}) {
	return { type, response_id: responseId, ...data };
}

function outputIndex(data, fallback) {
	return data?.output_index !== undefined ? String(data.output_index) : fallback;
}

function isEmptyToolInput(input) {
	return input === undefined || input === null || input === '' || input === '{}';
}

function unwrapToolInput(name, parameterName, body) {
	let input = body;
	if (parameterName === 'patch_text' || parameterName === 'patch') {
		input = body;
	} else {
		try {
			const parsed = JSON.parse(body);
			if (parsed && typeof parsed === 'object') {
				if (typeof parsed.patch_text === 'string') {
					input = parsed.patch_text;
				} else if (typeof parsed.input === 'string') {
					input = parsed.input;
				}
			}
		} catch {
			// Raw custom-tool input is valid when Mimo omits a parameter name.
		}
	}
	// The markup normally puts the payload on its own line. Remove only that
	// framing newline so the patch bytes themselves remain unchanged.
	if (/^\r?\n/.test(input)) input = input.replace(/^\r?\n/, '');
	if (/\r?\n$/.test(input)) input = input.replace(/\r?\n$/, '');

	return input;
}

function extractToolCalls(text) {
	FUNCTION_PATTERN.lastIndex = 0;
	const calls = [];
	let visibleText = '';
	let match;
	let lastIndex = 0;
	while ((match = FUNCTION_PATTERN.exec(text)) !== null) {
		visibleText += text.slice(lastIndex, match.index);
		let parameter = NAMED_PARAMETER_PATTERN.exec(match[2]) ?? RAW_PARAMETER_PATTERN.exec(match[2]);
		if (!parameter) {
			const missingOpening = MISSING_OPENING_PARAMETER_PATTERN.exec(match[2]);
			if (missingOpening?.[1].trim() && !POSSIBLE_TOOL_MARKUP.test(missingOpening[1])) {
				parameter = [missingOpening[0], undefined, missingOpening[1]];
			}
		}
		if (!parameter) {
			return { calls: [], malformed: true, reason: 'tool-call parameter markup is invalid' };
		}
		let parameterName;
		if (parameter.length > 2) parameterName = parameter[1];
		const parameterBody = parameter[2] ?? parameter[1];
		calls.push({
			name: match[1],
			input: unwrapToolInput(match[1], parameterName?.trim().toLowerCase(), parameterBody)
		});
		lastIndex = FUNCTION_PATTERN.lastIndex;
	}
	if (calls.length === 0) {
		return POSSIBLE_TOOL_MARKUP.test(text)
			? { calls: [], malformed: true, reason: 'incomplete or invalid tool-call markup' }
			: { calls: [], malformed: false, visibleText: text };
	}
	visibleText += text.slice(lastIndex);
	if (POSSIBLE_TOOL_MARKUP.test(visibleText)) {
		return { calls: [], malformed: true, reason: 'incomplete or invalid tool-call markup' };
	}

	return { calls, malformed: false, visibleText };
}

class MimoResponsesStreamAdapter extends Transform {
	constructor(options = {}) {
		super();
		this.decoder = new StringDecoder('utf8');
		this.buffer = '';
		this.messageItems = new Map();
		this.customItems = new Map();
		this.suppressedItemIds = new Set();
		this.synthesizedItems = new Map();
		this.replacedItems = new Map();
		this.chatMode = false;
		this.chatResponseId = `resp_mimo_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
		this.chatOutput = [];
		this.chatReasoning = null;
		this.chatMessage = null;
		this.chatTools = new Map();
		this.chatFinishReason = null;
		this.chatUsage = null;
		this.chatStarted = false;
		this.chatDone = false;
		this.completed = false;
		this.failed = false;
		this.model = options.model ?? 'unknown';
		this.logger = options.logger ?? console;
		this.namespaceMapping = options.namespaceMapping ?? null;
	}

	restoreToolItem(item) {
		return restoreMimoResponsesValue(item, this.namespaceMapping);
	}

	startChatResponse(data) {
		if (this.chatStarted) return;
		this.chatStarted = true;
		if (typeof data.id === 'string' && data.id.trim()) this.chatResponseId = data.id;
		this.emitEvent(
			'response.created',
			responseEvent('response.created', this.chatResponseId, {
				response: { id: this.chatResponseId, object: 'response', output: [] }
			})
		);
	}

	startChatMessage() {
		if (this.chatMessage) return;
		const item = {
			type: 'message',
			id: `${this.chatResponseId}_msg_0`,
			role: 'assistant',
			status: 'in_progress',
			content: []
		};
		this.chatMessage = { item, text: '', outputIndex: this.chatOutput.length, contentStarted: false, done: false };
		this.chatOutput.push(item);
		this.emitEvent(
			'response.output_item.added',
			responseEvent('response.output_item.added', this.chatResponseId, {
				output_index: this.chatMessage.outputIndex,
				item
			})
		);
	}

	startChatReasoning() {
		if (this.chatReasoning) return;
		const item = {
			type: 'reasoning',
			id: `${this.chatResponseId}_reasoning_0`,
			status: 'in_progress',
			summary: [],
			content: []
		};
		this.chatReasoning = { item, text: '', outputIndex: this.chatOutput.length, done: false };
		this.chatOutput.push(item);
		this.emitEvent(
			'response.output_item.added',
			responseEvent('response.output_item.added', this.chatResponseId, {
				output_index: this.chatReasoning.outputIndex,
				item
			})
		);
	}

	chatReasoningDelta(delta) {
		if (typeof delta !== 'string' || delta === '') return;
		this.startChatReasoning();
		this.chatReasoning.text += delta;
		this.emitEvent(
			'response.reasoning_text.delta',
			responseEvent('response.reasoning_text.delta', this.chatResponseId, {
				output_index: this.chatReasoning.outputIndex,
				item_id: this.chatReasoning.item.id,
				content_index: 0,
				delta
			})
		);
	}

	chatReasoningMessage(reasoningContent) {
		if (typeof reasoningContent !== 'string' || reasoningContent === '') return;
		const current = this.chatReasoning?.text ?? '';
		if (current === '') this.chatReasoningDelta(reasoningContent);
		else if (reasoningContent === current) {
			// The final Chat Completions message repeats streamed reasoning.
		} else if (reasoningContent.startsWith(current)) this.chatReasoningDelta(reasoningContent.slice(current.length));
		else {
			this.fail('final assistant reasoning conflicts with streamed reasoning', {
				output_index: this.chatReasoning?.outputIndex ?? -1
			});
		}
	}

	chatTextDelta(delta) {
		if (typeof delta !== 'string' || delta === '') return;
		this.startChatMessage();
		this.chatMessage.text += delta;
		if (!this.chatMessage.contentStarted) {
			this.chatMessage.contentStarted = true;
			this.emitEvent(
				'response.content_part.added',
				responseEvent('response.content_part.added', this.chatResponseId, {
					output_index: this.chatMessage.outputIndex,
					content_index: 0,
					part: { type: 'output_text', text: '' }
				})
			);
		}
		this.emitEvent(
			'response.output_text.delta',
			responseEvent('response.output_text.delta', this.chatResponseId, {
				output_index: this.chatMessage.outputIndex,
				content_index: 0,
				delta
			})
		);
	}

	chatToolStart(index, id, name) {
		const key = index === undefined || index === null || index === '' ? String(this.chatTools.size) : String(index);
		let state = this.chatTools.get(key);
		if (!state) {
			const callId = typeof id === 'string' && id ? id : `${this.chatResponseId}_call_${key}`;
			const item = this.restoreToolItem({
				type: 'function_call',
				id: callId,
				call_id: callId,
				name: typeof name === 'string' ? name : '',
				arguments: '',
				status: 'in_progress'
			});
			state = { key, item, outputIndex: this.chatOutput.length, done: false, generatedCallId: !id };
			this.chatTools.set(key, state);
			this.chatOutput.push(item);
			this.emitEvent(
				'response.output_item.added',
				responseEvent('response.output_item.added', this.chatResponseId, {
					output_index: state.outputIndex,
					item
				})
			);
		} else if (typeof name === 'string' && name && !state.item.name) {
			const restored = this.restoreToolItem({ type: 'function_call', name });
			state.item.name = restored.name;
			if (restored.namespace) state.item.namespace = restored.namespace;
		}

		return state;
	}

	chatToolArguments(index, argumentsDelta) {
		if (typeof argumentsDelta !== 'string' || argumentsDelta === '') return;
		const state = this.chatToolStart(index);
		state.item.arguments += argumentsDelta;
		this.emitEvent(
			'response.function_call_arguments.delta',
			responseEvent('response.function_call_arguments.delta', this.chatResponseId, {
				output_index: state.outputIndex,
				item_id: state.item.id,
				call_id: state.item.call_id,
				delta: argumentsDelta
			})
		);
	}

	findChatToolById(id) {
		if (typeof id !== 'string' || id === '') return null;
		for (const state of this.chatTools.values()) {
			if (state.item.call_id === id || state.item.id === id) return state;
		}

		return null;
	}

	chatToolMessage(index, toolCall) {
		const functionData = toolCall?.function ?? {};
		const restoredFunction = this.restoreToolItem({ type: 'function_call', name: functionData.name });
		const functionName = restoredFunction.name;
		const id = typeof toolCall?.id === 'string' ? toolCall.id : undefined;
		const existing = this.findChatToolById(id);
		const state = existing ?? this.chatToolStart(toolCall?.index ?? index, id, functionName);
		if (id && state.item.call_id !== id && !state.generatedCallId) {
			this.fail('tool call id conflicts with an earlier fragment', {
				output_index: state.outputIndex,
				tool: state.item.name ?? functionData.name ?? '(unknown)',
				input_bytes: Buffer.byteLength(state.item.arguments, 'utf8')
			});

			return;
		}
		if (typeof functionName === 'string' && functionName !== '') {
			if (state.item.name && state.item.name !== functionName) {
				this.fail('tool call name conflicts with an earlier fragment', {
					output_index: state.outputIndex,
					tool: state.item.name,
					input_bytes: Buffer.byteLength(state.item.arguments, 'utf8')
				});

				return;
			}
			state.item.name = functionName;
			if (restoredFunction.namespace) state.item.namespace = restoredFunction.namespace;
		}
		if (typeof functionData.arguments !== 'string') return;

		const completeArguments = functionData.arguments;
		const currentArguments = state.item.arguments;
		if (currentArguments === completeArguments) return;
		if (currentArguments !== '' && !completeArguments.startsWith(currentArguments)) {
			this.fail('tool call arguments conflict with earlier fragments', {
				output_index: state.outputIndex,
				tool: state.item.name ?? '(unknown)',
				input_bytes: Buffer.byteLength(currentArguments, 'utf8')
			});

			return;
		}
		this.chatToolArguments(state.key, completeArguments.slice(currentArguments.length));
	}

	chatMessageContent(message) {
		if (typeof message?.content === 'string') return message.content;
		if (!Array.isArray(message?.content)) return '';

		return message.content
			.map((part) => (typeof part === 'string' ? part : typeof part?.text === 'string' ? part.text : ''))
			.join('');
	}

	processChatMessage(message) {
		this.chatReasoningMessage(message?.reasoning_content);
		if (this.failed) return;
		const content = this.chatMessageContent(message);
		if (content !== '') {
			const current = this.chatMessage?.text ?? '';
			if (current === '') this.chatTextDelta(content);
			else if (content === current) {
				// The final Chat Completions message repeats streamed text.
			} else if (content.startsWith(current)) this.chatTextDelta(content.slice(current.length));
			else {
				this.fail('final assistant message conflicts with streamed text', {
					output_index: this.chatMessage?.outputIndex ?? -1
				});

				return;
			}
		}
		for (let index = 0; index < (message?.tool_calls ?? []).length; index += 1) {
			this.chatToolMessage(index, message.tool_calls[index]);
			if (this.failed) return;
		}
	}

	finishChatReasoning() {
		if (!this.chatReasoning || this.chatReasoning.done) return;
		this.chatReasoning.done = true;
		this.chatReasoning.item.content = [{ type: 'reasoning_text', text: this.chatReasoning.text }];
		this.chatReasoning.item.status = 'completed';
		this.emitEvent(
			'response.reasoning_text.done',
			responseEvent('response.reasoning_text.done', this.chatResponseId, {
				output_index: this.chatReasoning.outputIndex,
				item_id: this.chatReasoning.item.id,
				content_index: 0,
				text: this.chatReasoning.text
			})
		);
		this.emitEvent(
			'response.output_item.done',
			responseEvent('response.output_item.done', this.chatResponseId, {
				output_index: this.chatReasoning.outputIndex,
				item: this.chatReasoning.item
			})
		);
	}

	finishChatMessage() {
		if (!this.chatMessage || this.chatMessage.done) return;
		this.chatMessage.done = true;
		if (this.chatMessage.contentStarted) {
			this.emitEvent(
				'response.output_text.done',
				responseEvent('response.output_text.done', this.chatResponseId, {
					output_index: this.chatMessage.outputIndex,
					content_index: 0,
					text: this.chatMessage.text
				})
			);
			this.emitEvent(
				'response.content_part.done',
				responseEvent('response.content_part.done', this.chatResponseId, {
					output_index: this.chatMessage.outputIndex,
					content_index: 0,
					part: { type: 'output_text', text: this.chatMessage.text }
				})
			);
		}
		this.chatMessage.item.content = [{ type: 'output_text', text: this.chatMessage.text }];
		this.chatMessage.item.status = 'completed';
		this.emitEvent(
			'response.output_item.done',
			responseEvent('response.output_item.done', this.chatResponseId, {
				output_index: this.chatMessage.outputIndex,
				item: this.chatMessage.item
			})
		);
	}

	finishChatTools() {
		for (const state of this.chatTools.values()) {
			if (state.done) continue;
			state.done = true;
			state.item.status = 'completed';
			this.emitEvent(
				'response.function_call_arguments.done',
				responseEvent('response.function_call_arguments.done', this.chatResponseId, {
					output_index: state.outputIndex,
					item_id: state.item.id,
					call_id: state.item.call_id,
					name: state.item.name,
					...(state.item.namespace ? { namespace: state.item.namespace } : {}),
					arguments: state.item.arguments
				})
			);
			this.emitEvent(
				'response.output_item.done',
				responseEvent('response.output_item.done', this.chatResponseId, {
					output_index: state.outputIndex,
					item: state.item
				})
			);
		}
	}

	finishChatResponse() {
		if (this.chatDone) return;
		this.chatDone = true;
		if (this.chatFinishReason === 'tool_calls' && this.chatTools.size === 0) {
			this.fail('finish_reason tool_calls without a tool call', { output_index: -1 });

			return;
		}
		for (const state of this.chatTools.values()) {
			if (!state.item.name) {
				this.fail('tool call is missing a function name', {
					output_index: state.outputIndex,
					tool: '(unknown)',
					input_bytes: Buffer.byteLength(state.item.arguments, 'utf8')
				});

				return;
			}
			if (typeof state.item.arguments !== 'string' || state.item.arguments.trim() === '') {
				this.fail('tool call is missing arguments', {
					output_index: state.outputIndex,
					tool: state.item.name,
					input_bytes: 0
				});

				return;
			}
			try {
				JSON.parse(state.item.arguments);
			} catch {
				this.fail('tool call arguments are malformed JSON', {
					output_index: state.outputIndex,
					tool: state.item.name,
					input_bytes: Buffer.byteLength(state.item.arguments, 'utf8')
				});

				return;
			}
		}
		this.finishChatReasoning();
		this.finishChatMessage();
		this.finishChatTools();
		this.completed = true;
		this.emitEvent(
			'response.completed',
			responseEvent('response.completed', this.chatResponseId, {
				response: {
					id: this.chatResponseId,
					object: 'response',
					status: 'completed',
					output: this.chatOutput,
					output_count: this.chatOutput.length,
					...(this.chatUsage ? { usage: this.chatUsage } : {})
				}
			})
		);
	}

	processChatFrame(data) {
		this.chatMode = true;
		this.startChatResponse(data);
		if (data.usage) this.chatUsage = data.usage;
		for (const choice of data.choices ?? []) {
			if (choice.finish_reason) this.chatFinishReason = choice.finish_reason;
			const delta = choice.delta ?? {};
			this.chatReasoningDelta(delta.reasoning_content);
			this.chatTextDelta(delta.content);
			for (const toolCall of delta.tool_calls ?? []) {
				const state = this.chatToolStart(toolCall.index, toolCall.id, toolCall.function?.name);
				if (typeof toolCall.function?.arguments === 'string') this.chatToolArguments(state.key, toolCall.function.arguments);
			}
			if (choice.message) this.processChatMessage(choice.message);
			if (this.failed) return;
		}
	}

	_transform(chunk, _encoding, callback) {
		try {
			this.buffer += this.decoder.write(chunk);
			this.drainFrames();
			callback();
		} catch (error) {
			callback(error);
		}
	}

	_flush(callback) {
		try {
			this.buffer += this.decoder.end();
			this.drainFrames(true);
			if (this.chatMode && !this.chatDone && !this.failed) this.fail('upstream ended before [DONE]', { output_index: -1 });
			if (!this.completed && !this.failed) {
				this.fail('upstream ended before response.completed');
			}
			callback();
		} catch (error) {
			callback(error);
		}
	}

	drainFrames(flush = false) {
		while (true) {
			const separator = /\r?\n\r?\n/.exec(this.buffer);
			if (!separator) break;
			const raw = this.buffer.slice(0, separator.index + separator[0].length);
			this.buffer = this.buffer.slice(separator.index + separator[0].length);
			this.processFrame(parseSseFrame(raw));
			if (this.failed) return;
		}
		if (flush && this.buffer.trim() !== '') {
			this.processFrame(parseSseFrame(this.buffer));
			this.buffer = '';
		}
	}

	emitRaw(raw) {
		this.push(Buffer.from(raw, 'utf8'));
	}

	emitFrame(frame) {
		if (!this.namespaceMapping || !frame.data) {
			this.emitRaw(frame.raw);

			return;
		}
		const restored = restoreMimoResponsesValue(frame.data, this.namespaceMapping);
		this.emitEvent(frame.eventName ?? restored.type ?? '', restored);
	}

	emitEvent(type, data) {
		this.emitRaw(encodeSse(type, data));
	}

	logDiagnostic(message, details = {}) {
		const payload = Object.entries(details)
			.map(([key, value]) => `${key}=${value}`)
			.join(' ');
		const line = `[mimo-responses-adapter] ${message}${payload ? ` ${payload}` : ''}`;
		if (typeof this.logger === 'function') this.logger(line);
		else if (this.logger && typeof this.logger.error === 'function') this.logger.error(line);
	}

	fail(reason, details = {}) {
		if (this.failed || this.completed) return;
		this.failed = true;
		this.logDiagnostic(reason, { model: this.model, ...details });
		this.emitEvent('response.failed', {
			type: 'response.failed',
			error: { code: 'mimo_tool_call_parse_error', message: reason }
		});
	}

	getMessageState(index) {
		if (!this.messageItems.has(index)) {
			this.messageItems.set(index, { index, frames: [], text: '', item: null, done: false });
		}

		return this.messageItems.get(index);
	}

	getCustomState(index) {
		if (!this.customItems.has(index)) {
			this.customItems.set(index, {
				index,
				frames: [],
				item: null,
				structured: false,
				hasInputEvents: false,
				synthesized: false,
				passed: false
			});
		}

		return this.customItems.get(index);
	}

	flushCustomState(state) {
		if (state.passed || state.synthesized) return;
		for (const frame of state.frames) this.emitFrame(frame);
		state.frames = [];
		state.passed = true;
	}

	flushMessageState(state) {
		for (const frame of state.frames) this.emitFrame(frame);
		state.frames = [];
	}

	messageResponseId(state) {
		return state.frames.find((frame) => typeof frame.data?.response_id === 'string')?.data.response_id;
	}

	messageOutputIndex(state) {
		return Number.isNaN(Number(state.index)) ? state.index : Number(state.index);
	}

	emitVisibleMessage(state, text) {
		const sourceItem = state.item ?? {};
		const itemId = String(sourceItem.id ?? `mimo-message-${state.index}`);
		const responseId = this.messageResponseId(state);
		const base = { output_index: this.messageOutputIndex(state) };
		const item = {
			...sourceItem,
			type: 'message',
			id: itemId,
			role: sourceItem.role ?? 'assistant',
			status: 'in_progress',
			content: []
		};
		this.emitEvent('response.output_item.added', responseEvent('response.output_item.added', responseId, { ...base, item }));
		this.emitEvent(
			'response.content_part.added',
			responseEvent('response.content_part.added', responseId, {
				...base,
				content_index: 0,
				part: { type: 'output_text', text: '' }
			})
		);
		if (text !== '') {
			this.emitEvent(
				'response.output_text.delta',
				responseEvent('response.output_text.delta', responseId, {
					...base,
					content_index: 0,
					delta: text
				})
			);
		}
		this.emitEvent(
			'response.output_text.done',
			responseEvent('response.output_text.done', responseId, {
				...base,
				content_index: 0,
				text
			})
		);
		this.emitEvent(
			'response.content_part.done',
			responseEvent('response.content_part.done', responseId, {
				...base,
				content_index: 0,
				part: { type: 'output_text', text }
			})
		);
		const completedItem = {
			...item,
			status: 'completed',
			content: [{ type: 'output_text', text }]
		};
		this.emitEvent(
			'response.output_item.done',
			responseEvent('response.output_item.done', responseId, { ...base, item: completedItem })
		);
		this.replacedItems.set(itemId, completedItem);
		state.frames = [];
	}

	synthesizeToolCall(state, call, ordinal) {
		this.logDiagnostic('converted textual tool call', {
			model: this.model,
			tool: call.name,
			input_bytes: Buffer.byteLength(call.input, 'utf8')
		});
		const sourceItem = state?.item ?? {};
		const itemId = String(sourceItem.id ?? `mimo-custom-tool-${state?.index ?? ordinal}`);
		const item = this.restoreToolItem({
			...sourceItem,
			type: 'custom_tool_call',
			id: itemId,
			name: call.name,
			input: ''
		});
		const index = state?.index ?? String(ordinal);
		const base = { output_index: Number.isNaN(Number(index)) ? index : Number(index) };
		this.emitEvent('response.output_item.added', { type: 'response.output_item.added', ...base, item });
		this.emitEvent('response.custom_tool_call_input.delta', {
			type: 'response.custom_tool_call_input.delta',
			...base,
			item_id: itemId,
			delta: call.input
		});
		this.emitEvent('response.custom_tool_call_input.done', {
			type: 'response.custom_tool_call_input.done',
			...base,
			item_id: itemId,
			input: call.input
		});
		const completedItem = { ...item, input: call.input };
		this.emitEvent('response.output_item.done', {
			type: 'response.output_item.done',
			...base,
			item: completedItem
		});
		this.synthesizedItems.set(itemId, completedItem);
		if (state) {
			state.synthesized = true;
			state.passed = true;
			state.frames = [];
		}
	}

	finalizeMessage(state) {
		if (state.done || this.failed) return;
		state.done = true;
		const extracted = extractToolCalls(state.text);
		if (extracted.malformed) {
			this.fail(extracted.reason, { output_index: state.index });

			return;
		}
		if (extracted.calls.length > 0) {
			const emptyCustom = [...this.customItems.values()]
				.filter((custom) => !custom.structured && !custom.synthesized && !custom.passed)
				.sort((left, right) => Number(left.index) - Number(right.index));
			if (extracted.calls.length > emptyCustom.length && emptyCustom.length !== 0) {
				this.fail('tool-call count does not match upstream custom-tool items', { output_index: state.index });

				return;
			}
			if (extracted.visibleText.trim() !== '') this.emitVisibleMessage(state, extracted.visibleText);
			else {
				this.suppressedItemIds.add(String(state.item?.id ?? state.index));
				state.frames = [];
			}
			for (let ordinal = 0; ordinal < extracted.calls.length; ordinal++) {
				this.synthesizeToolCall(emptyCustom[ordinal], extracted.calls[ordinal], ordinal);
			}

			return;
		}
		this.flushMessageState(state);
	}

	finalizePending() {
		for (const state of this.messageItems.values()) this.finalizeMessage(state);
		if (this.failed) return;
		for (const state of this.customItems.values()) {
			if (!state.structured && !state.synthesized && !state.passed) {
				if (state.hasInputEvents) {
					state.structured = true;
					this.flushCustomState(state);

					continue;
				}
				this.fail('upstream emitted an incomplete custom tool call', { output_index: state.index });

				return;
			}
		}
	}

	mutateCompletion(data) {
		const result = { ...data };
		if (result.response && typeof result.response === 'object') {
			result.response = { ...result.response };
			if (Array.isArray(result.response.output)) {
				result.response.output = result.response.output
					.map(
						(item) => this.replacedItems.get(String(item?.id ?? '')) ?? this.synthesizedItems.get(String(item?.id ?? '')) ?? item
					)
					.filter((item) => !this.suppressedItemIds.has(String(item?.id ?? '')));
				if (typeof result.response.output_count === 'number') {
					result.response.output_count = result.response.output.length;
				}
			}
		}
		if (typeof result.output_count === 'number' && result.response?.output) {
			result.output_count = result.response.output.length;
		}

		return result;
	}

	processFrame(frame) {
		if (this.failed || !frame.data) {
			if (!this.failed && frame.doneToken && this.chatMode) this.finishChatResponse();
			else if (!this.failed && frame.doneToken) this.emitRaw(frame.raw);

			return;
		}
		if (frame.invalidJson) {
			this.emitRaw(frame.raw);

			return;
		}
		const data = frame.data;
		if (Array.isArray(data.choices)) {
			this.processChatFrame(data);

			return;
		}
		const type = String(data.type ?? frame.eventName ?? '');
		if (type === 'response.output_item.added') {
			const item = data.item;
			if (item?.type === 'custom_tool_call') {
				const state = this.getCustomState(outputIndex(data, String(item.id ?? 'custom')));
				state.frames.push(frame);
				state.item = item;
				if (!isEmptyToolInput(item.input)) {
					state.structured = true;
					this.flushCustomState(state);
				}

				return;
			}
			if (item?.type === 'message') {
				const state = this.getMessageState(outputIndex(data, String(item.id ?? 'message')));
				state.frames.push(frame);
				state.item = item;

				return;
			}
		}

		const index = outputIndex(data, null);
		const message = index === null ? null : this.messageItems.get(index);
		const custom = index === null ? null : this.customItems.get(index);
		if (type === 'response.output_text.delta' && message) {
			message.frames.push(frame);
			message.text += typeof data.delta === 'string' ? data.delta : '';

			return;
		}
		if (message && ['response.content_part.added', 'response.output_text.done', 'response.content_part.done'].includes(type)) {
			message.frames.push(frame);

			return;
		}
		if (type === 'response.output_item.done' && message && (data.item?.type === 'message' || !data.item?.type)) {
			message.frames.push(frame);

			return;
		}
		if (custom && type.startsWith('response.custom_tool_call_input.')) {
			if (custom.synthesized) return;
			custom.hasInputEvents = true;
			if (custom.structured || custom.passed) this.emitFrame(frame);
			else custom.frames.push(frame);

			return;
		}
		if (type === 'response.output_item.done' && custom) {
			if (custom.synthesized) return;
			if (custom.structured || custom.passed) this.emitFrame(frame);
			else custom.frames.push(frame);

			return;
		}
		if (type === 'response.completed') {
			this.finalizePending();
			if (this.failed) return;
			this.completed = true;
			this.emitEvent(type, this.mutateCompletion(restoreMimoResponsesValue(data, this.namespaceMapping)));

			return;
		}
		if (type === 'response.failed') this.completed = true;
		this.emitFrame(frame);
	}
}

export function createMimoResponsesStreamAdapter(options) {
	return new MimoResponsesStreamAdapter(options);
}

export { extractToolCalls };
