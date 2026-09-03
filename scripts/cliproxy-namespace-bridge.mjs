import http from 'node:http';
import https from 'node:https';
import { resolve } from 'node:path';
import { Transform, pipeline } from 'node:stream';
import { StringDecoder } from 'node:string_decoder';
import { pathToFileURL } from 'node:url';

const SERVICE_NAME = 'cliproxy-namespace-bridge';
const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_PORT = 8318;
const DEFAULT_UPSTREAM = 'http://127.0.0.1:8317';
const DEFAULT_MAX_BODY_BYTES = 128 * 1024 * 1024;
const DEFAULT_MAX_INPUT_TOKENS = 500_000;
const HOP_BY_HOP_HEADERS = new Set([
	'connection',
	'keep-alive',
	'proxy-authenticate',
	'proxy-authorization',
	'te',
	'trailer',
	'transfer-encoding',
	'upgrade'
]);
const EXPECTED_DISCONNECT_CODES = new Set(['ECONNRESET', 'ERR_STREAM_PREMATURE_CLOSE', 'ERR_STREAM_UNABLE_TO_PIPE']);

class BridgeRequestError extends Error {
	constructor(statusCode, code, message) {
		super(message);
		this.statusCode = statusCode;
		this.code = code;
	}
}

class BridgeResponseError extends Error {
	constructor(code, message = 'CLIProxyAPI returned an invalid tool call.') {
		super(message);
		this.code = code;
	}
}

function isObject(value) {
	return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function tokenCount(value) {
	return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : null;
}

function firstTokenCount(...values) {
	for (const value of values) {
		const count = tokenCount(value);
		if (count !== null) return count;
	}

	return null;
}

function normalizeUsage(usage, { maxInputTokens = DEFAULT_MAX_INPUT_TOKENS, logger, model } = {}) {
	if (!isObject(usage)) return undefined;
	const inputTokens = firstTokenCount(usage.input_tokens, usage.prompt_tokens);
	const outputTokens = firstTokenCount(usage.output_tokens, usage.completion_tokens);
	if (inputTokens === null || outputTokens === null || inputTokens > maxInputTokens) {
		if (inputTokens !== null && inputTokens > maxInputTokens) {
			logger?.warn?.(
				`[${SERVICE_NAME}] ignored upstream usage model=${model ?? 'unknown'} input_tokens=${inputTokens} max_input_tokens=${maxInputTokens}`
			);
		}

		return undefined;
	}

	const cachedTokens = firstTokenCount(
		usage.input_tokens_details?.cached_tokens,
		usage.prompt_tokens_details?.cached_tokens,
		usage.cached_input_tokens,
		usage.prompt_cache_hit_tokens,
		usage.cache_read_input_tokens
	);
	const normalized = {
		input_tokens: inputTokens,
		output_tokens: outputTokens,
		total_tokens: inputTokens + outputTokens
	};
	if (cachedTokens !== null && cachedTokens <= inputTokens) {
		normalized.input_tokens_details = { cached_tokens: cachedTokens };
	}

	return normalized;
}

function namespaceKey(namespace, name) {
	return `${namespace}\u0000${name}`;
}

function makeFlatToolName(namespace, name) {
	return `${namespace.replace(/__+$/u, '')}__${name}`;
}

function emptyMapping() {
	return {
		fullToOriginal: new Map(),
		namespaceToolToFlat: new Map(),
		uniqueBareToOriginal: new Map(),
		namespaceOnlyToOriginal: new Map(),
		customToolNames: new Set()
	};
}

function directToolName(tool) {
	if (typeof tool?.name === 'string') return tool.name;
	if (isObject(tool?.function) && typeof tool.function.name === 'string') return tool.function.name;

	return undefined;
}

function cloneFunctionTool(innerTool, flatName) {
	const flattened = { ...innerTool, type: 'function', name: flatName };
	const parameters = innerTool.parameters ?? innerTool.input_schema ?? innerTool.inputSchema;

	delete flattened.namespace;
	delete flattened.input_schema;
	delete flattened.inputSchema;
	if (parameters !== undefined) flattened.parameters = parameters;

	return flattened;
}

function customInputDescription(tool) {
	const base = 'The complete freeform input for this tool.';
	if (tool?.format?.type !== 'grammar' || typeof tool.format.definition !== 'string') return base;
	const syntax = typeof tool.format.syntax === 'string' ? tool.format.syntax : 'specified';

	return `${base} It must match this ${syntax} grammar:\n${tool.format.definition}`;
}

function adaptCustomTool(tool) {
	return {
		type: 'function',
		name: tool.name,
		...(typeof tool.description === 'string' ? { description: tool.description } : {}),
		strict: false,
		parameters: {
			type: 'object',
			properties: { input: { type: 'string', description: customInputDescription(tool) } },
			required: ['input'],
			additionalProperties: false
		}
	};
}

function isAdaptedCustomTool(name, mapping) {
	return typeof name === 'string' && mapping?.customToolNames?.has(name) === true;
}

function customInputFromArguments(argumentsJson) {
	if (typeof argumentsJson !== 'string') return null;
	try {
		const parsed = JSON.parse(argumentsJson);

		return isObject(parsed) && typeof parsed.input === 'string' ? parsed.input : null;
	} catch {
		return null;
	}
}

const EXEC_WAIT_CALL_RE = /^await\s+tools\.wait\s*\(([\s\S]*)\)\s*;?\s*$/u;
const EXEC_YIELD_CELL_RE = /Script running with cell ID\s+(\S+)/u;
const SYNTHETIC_WAIT_YIELD_MS = 60_000;

export function parseExecWaitCall(input) {
	if (typeof input !== 'string') return null;
	const stripped = input
		.replace(/^\uFEFF/u, '')
		.replace(/^\s*\/\/\s*@exec:[^\n]*\n/u, '')
		.trim();
	const match = EXEC_WAIT_CALL_RE.exec(stripped);
	if (!match) return null;
	const raw = match[1].trim();
	if (!raw.startsWith('{') || !raw.endsWith('}')) return null;
	const cell = /\bcell_id\s*:\s*(['"])([^'"]+)\1/u.exec(raw);
	if (!cell) return null;
	const args = { cell_id: cell[2] };
	const yieldMs = /\byield_time_ms\s*:\s*(\d+)/u.exec(raw);
	if (yieldMs) args.yield_time_ms = Number(yieldMs[1]);
	const maxTokens = /\bmax_tokens\s*:\s*(\d+)/u.exec(raw);
	if (maxTokens) args.max_tokens = Number(maxTokens[1]);
	const terminate = /\bterminate\s*:\s*(true|false)/u.exec(raw);
	if (terminate) args.terminate = terminate[1] === 'true';

	return args;
}

function execWaitInputFromToolCall(value) {
	if (!isObject(value)) return null;
	const name = typeof value.name === 'string' ? value.name : '';
	if (name !== 'exec') return null;
	if (typeof value.input === 'string') return value.input;
	if (typeof value.arguments === 'string') return customInputFromArguments(value.arguments);

	return null;
}

export function rewriteExecWaitToolCall(value) {
	const input = execWaitInputFromToolCall(value);
	if (input === null) return value;
	const args = parseExecWaitCall(input);
	if (!args) return value;
	const rewritten = {
		type: 'function_call',
		name: 'wait',
		arguments: JSON.stringify(args),
		status: typeof value.status === 'string' ? value.status : 'completed'
	};
	if (typeof value.id === 'string') rewritten.id = value.id;
	if (typeof value.call_id === 'string') rewritten.call_id = value.call_id;
	else if (typeof value.id === 'string') rewritten.call_id = value.id;

	return rewritten;
}

function toolOutputText(value) {
	if (typeof value === 'string') return value;
	if (Array.isArray(value)) {
		return value.map((part) => toolOutputText(part)).join('');
	}
	if (!isObject(value)) return '';
	if (typeof value.text === 'string') return value.text;
	if (typeof value.input_text === 'string') return value.input_text;

	return '';
}

function isToolOutputItem(item) {
	if (!isObject(item)) return false;

	return item.type === 'custom_tool_call_output' || item.type === 'function_call_output' || item.role === 'tool';
}

function itemOutputText(item) {
	if (!isObject(item)) return '';
	if (item.type === 'custom_tool_call_output' || item.type === 'function_call_output') {
		return toolOutputText(item.output ?? item.content);
	}
	if (item.role === 'tool') return toolOutputText(item.content ?? item.output);

	return '';
}

function collectConversationItems(value, acc = []) {
	if (Array.isArray(value)) {
		for (const item of value) collectConversationItems(item, acc);

		return acc;
	}
	if (!isObject(value)) return acc;
	acc.push(value);
	if (Array.isArray(value.content)) collectConversationItems(value.content, acc);

	return acc;
}

export function unresolvedYieldCellId(body) {
	const sources = [];
	if (Array.isArray(body)) sources.push(body);
	else if (isObject(body)) {
		if (body.input !== undefined) sources.push(body.input);
		if (body.messages !== undefined) sources.push(body.messages);
	}
	const items = [];
	for (const source of sources) collectConversationItems(source, items);
	for (let index = items.length - 1; index >= 0; index -= 1) {
		const item = items[index];
		if (!isToolOutputItem(item)) continue;
		const match = EXEC_YIELD_CELL_RE.exec(itemOutputText(item));

		return match ? match[1] : null;
	}

	return null;
}

export function requestHasWaitTool(body) {
	const tools = Array.isArray(body) ? body : Array.isArray(body?.tools) ? body.tools : [];

	return tools.some((tool) => {
		if (!isObject(tool) || tool.type === 'namespace') return false;
		if (tool.name === 'wait') return true;

		return isObject(tool.function) && tool.function.name === 'wait';
	});
}

function outputHasToolCall(output) {
	if (!Array.isArray(output)) return false;

	return output.some((item) => item?.type === 'function_call' || item?.type === 'custom_tool_call');
}

function syntheticWaitFunctionCall(responseId, cellId) {
	const id = `${responseId}_wait_yield`;

	return {
		type: 'function_call',
		id,
		call_id: id,
		name: 'wait',
		arguments: JSON.stringify({ cell_id: cellId, yield_time_ms: SYNTHETIC_WAIT_YIELD_MS }),
		status: 'completed'
	};
}

function logInjectedWait(logger, model, cellId) {
	logger?.log?.(`[${SERVICE_NAME}] injected wait after unresolved exec yield cell_id=${cellId} model=${model ?? 'unknown'}`);
}

export function applyUnresolvedYieldWait(value, options = {}) {
	if (!isObject(value)) return value;
	const yieldCellId = typeof options.yieldCellId === 'string' ? options.yieldCellId.trim() : '';
	if (yieldCellId === '' || options.waitToolAvailable !== true) return value;

	const inject = (response, responseIdFallback) => {
		if (!isObject(response)) return { next: response, injected: false };
		const output = Array.isArray(response.output) ? response.output : [];
		if (outputHasToolCall(output)) return { next: response, injected: false };
		const responseId = typeof response.id === 'string' && response.id.trim() !== '' ? response.id : responseIdFallback;
		const waitItem = syntheticWaitFunctionCall(responseId, yieldCellId);
		const nextOutput = [...output, waitItem];
		logInjectedWait(options.logger, options.model, yieldCellId);

		return {
			next: { ...response, id: responseId, output: nextOutput, output_count: nextOutput.length },
			injected: true
		};
	};

	if (Array.isArray(value.output) || value.object === 'response') {
		const result = inject(value, value.id ?? newResponseId());

		return result.injected ? result.next : value;
	}
	if (isObject(value.response)) {
		const result = inject(value.response, value.response.id ?? value.response_id ?? newResponseId());
		if (!result.injected) return value;

		return { ...value, response: result.next };
	}

	return value;
}

function addBareCandidate(candidates, original) {
	const current = candidates.get(original.name);
	if (current === undefined) {
		candidates.set(original.name, original);

		return;
	}
	if (current && (current.namespace !== original.namespace || current.name !== original.name)) {
		candidates.set(original.name, null);
	}
}

function resolveOriginal(name, mapping) {
	return (
		mapping?.fullToOriginal?.get(name) ??
		mapping?.uniqueBareToOriginal?.get(name) ??
		mapping?.namespaceOnlyToOriginal?.get(name) ??
		null
	);
}

function flattenNamespacedName(value, mapping) {
	if (!isObject(value) || typeof value.namespace !== 'string' || typeof value.name !== 'string') return value;
	const flatName = mapping.namespaceToolToFlat.get(namespaceKey(value.namespace, value.name));
	if (!flatName) return value;

	const rewritten = { ...value, name: flatName };
	delete rewritten.namespace;

	return rewritten;
}

function rewriteValueForUpstream(value, mapping) {
	if (Array.isArray(value)) return value.map((item) => rewriteValueForUpstream(item, mapping));
	if (!isObject(value)) return value;

	let rewritten = {};
	for (const [key, child] of Object.entries(value)) rewritten[key] = rewriteValueForUpstream(child, mapping);

	if (isObject(rewritten.function)) rewritten.function = flattenNamespacedName(rewritten.function, mapping);
	if (isObject(rewritten.function_call)) rewritten.function_call = flattenNamespacedName(rewritten.function_call, mapping);
	if (rewritten.type === 'custom_tool_call' && isAdaptedCustomTool(rewritten.name, mapping)) {
		rewritten.type = 'function_call';
		rewritten.arguments = JSON.stringify({ input: typeof rewritten.input === 'string' ? rewritten.input : '' });
		delete rewritten.input;
	}
	if (rewritten.type === 'custom_tool_call_output') rewritten.type = 'function_call_output';
	if (
		(rewritten.type === 'function_call' || rewritten.type === 'function') &&
		typeof rewritten.namespace === 'string' &&
		typeof rewritten.name === 'string'
	) {
		rewritten = flattenNamespacedName(rewritten, mapping);
	}

	return rewritten;
}

function rewriteToolChoiceForUpstream(toolChoice, mapping) {
	if (!isObject(toolChoice)) return toolChoice;

	const namespaced =
		typeof toolChoice.namespace === 'string' && typeof toolChoice.name === 'string'
			? mapping.namespaceToolToFlat.get(namespaceKey(toolChoice.namespace, toolChoice.name))
			: null;
	if (namespaced) {
		const rewritten = { ...toolChoice, type: 'function', name: namespaced };
		delete rewritten.namespace;

		return rewritten;
	}
	if (toolChoice.type === 'custom' && isAdaptedCustomTool(toolChoice.name, mapping)) {
		return { ...toolChoice, type: 'function' };
	}

	return rewriteValueForUpstream(toolChoice, mapping);
}

export function flattenOpenAiRequest(body) {
	if (!isObject(body)) {
		throw new BridgeRequestError(400, 'invalid_request_body', 'OpenAI request body must be a JSON object.');
	}

	const tools = Array.isArray(body.tools) ? body.tools : [];
	const directNames = new Set(
		tools
			.filter((tool) => isObject(tool) && tool.type !== 'namespace')
			.map(directToolName)
			.filter((name) => typeof name === 'string')
	);
	const usedNames = new Set(directNames);
	const fullToOriginal = new Map();
	const namespaceToolToFlat = new Map();
	const bareCandidates = new Map();
	const namespaceOnlyCandidates = new Map();
	const customToolNames = new Set();
	const flattenedTools = [];

	for (const tool of tools) {
		if (isObject(tool) && tool.type === 'custom' && typeof tool.name === 'string' && tool.name.trim() !== '') {
			customToolNames.add(tool.name);
			flattenedTools.push(adaptCustomTool(tool));
			continue;
		}
		if (!isObject(tool) || tool.type !== 'namespace') {
			flattenedTools.push(tool);
			continue;
		}

		const namespace = tool.name;
		const innerTools = Array.isArray(tool.tools) ? tool.tools : tool.functions;
		if (typeof namespace !== 'string' || namespace.trim() === '' || !Array.isArray(innerTools)) {
			throw new BridgeRequestError(400, 'invalid_namespace_tool', 'Namespace tools require a non-empty name and a tools array.');
		}

		for (const innerTool of innerTools) {
			if (!isObject(innerTool) || typeof innerTool.name !== 'string' || innerTool.name.trim() === '') {
				throw new BridgeRequestError(400, 'invalid_namespace_tool', 'Namespace tool contains an invalid function name.');
			}

			const flatName = makeFlatToolName(namespace, innerTool.name);
			if (usedNames.has(flatName)) {
				throw new BridgeRequestError(400, 'tool_name_collision', 'Flattened tool name collides with another tool.');
			}

			const original = { namespace, name: innerTool.name };
			usedNames.add(flatName);
			fullToOriginal.set(flatName, original);
			namespaceToolToFlat.set(namespaceKey(namespace, innerTool.name), flatName);
			addBareCandidate(bareCandidates, original);
			const namespaceCandidate = namespaceOnlyCandidates.get(namespace);
			if (namespaceCandidate === undefined) namespaceOnlyCandidates.set(namespace, original);
			else namespaceOnlyCandidates.set(namespace, null);
			flattenedTools.push(cloneFunctionTool(innerTool, flatName));
		}
	}

	for (const directName of directNames) {
		if (bareCandidates.has(directName)) bareCandidates.set(directName, null);
		if (namespaceOnlyCandidates.has(directName)) namespaceOnlyCandidates.set(directName, null);
	}

	const mapping = {
		fullToOriginal,
		namespaceToolToFlat,
		uniqueBareToOriginal: new Map([...bareCandidates.entries()].filter(([, original]) => original !== null)),
		namespaceOnlyToOriginal: new Map([...namespaceOnlyCandidates.entries()].filter(([, original]) => original !== null)),
		customToolNames
	};
	const rewritten = { ...body };
	if (Array.isArray(body.tools)) rewritten.tools = flattenedTools;
	if (body.input !== undefined) rewritten.input = rewriteValueForUpstream(body.input, mapping);
	if (body.messages !== undefined) rewritten.messages = rewriteValueForUpstream(body.messages, mapping);
	if (body.tool_choice !== undefined) rewritten.tool_choice = rewriteToolChoiceForUpstream(body.tool_choice, mapping);

	return { body: rewritten, mapping };
}

export function flattenResponsesRequest(body) {
	return flattenOpenAiRequest(body);
}

export function canonicalizeArguments(argumentsJson) {
	if (typeof argumentsJson !== 'string' || argumentsJson.length === 0) return argumentsJson;
	try {
		return JSON.stringify(JSON.parse(argumentsJson));
	} catch {
		return argumentsJson;
	}
}

function restoreFunctionName(value, mapping, includeNamespace) {
	if (!isObject(value) || typeof value.name !== 'string') return value;
	const original = resolveOriginal(value.name, mapping);
	if (!original) return value;

	const restored = { ...value, name: original.name };
	if (includeNamespace) restored.namespace = original.namespace;

	return restored;
}

function rewriteValueForClient(value, mapping, { includeNamespace = true } = {}) {
	if (Array.isArray(value)) return value.map((item) => rewriteValueForClient(item, mapping, { includeNamespace }));
	if (!isObject(value)) return value;

	let rewritten = {};
	for (const [key, child] of Object.entries(value)) {
		rewritten[key] = rewriteValueForClient(child, mapping, { includeNamespace });
	}

	if (isObject(rewritten.function) && typeof rewritten.function.name === 'string') {
		const original = resolveOriginal(rewritten.function.name, mapping);
		rewritten.function = restoreFunctionName(rewritten.function, mapping, false);
		if (original && includeNamespace) rewritten.namespace = original.namespace;
		if (typeof rewritten.function.arguments === 'string' && rewritten.type === 'function') {
			rewritten.function.arguments = canonicalizeArguments(rewritten.function.arguments);
		}
	}
	if (isObject(rewritten.function_call)) {
		rewritten.function_call = restoreFunctionName(rewritten.function_call, mapping, includeNamespace);
		if (typeof rewritten.function_call.arguments === 'string') {
			rewritten.function_call.arguments = canonicalizeArguments(rewritten.function_call.arguments);
		}
	}
	const isFunctionCall = rewritten.type === 'function_call';
	const isCompletedArguments = rewritten.type === 'response.function_call_arguments.done';
	if (isFunctionCall || isCompletedArguments) {
		if (typeof rewritten.name === 'string') rewritten = restoreFunctionName(rewritten, mapping, includeNamespace);
		if (typeof rewritten.arguments === 'string') rewritten.arguments = canonicalizeArguments(rewritten.arguments);
	}
	if (isFunctionCall && isAdaptedCustomTool(rewritten.name, mapping)) {
		const input = rewritten.arguments === '' ? '' : customInputFromArguments(rewritten.arguments);
		if (input !== null) {
			rewritten.type = 'custom_tool_call';
			rewritten.input = input;
			delete rewritten.arguments;
			delete rewritten.namespace;
		}
	}
	if (isCompletedArguments && isAdaptedCustomTool(rewritten.name, mapping)) {
		const input = customInputFromArguments(rewritten.arguments);
		if (input !== null) {
			rewritten.type = 'response.custom_tool_call_input.done';
			rewritten.input = input;
			delete rewritten.arguments;
			delete rewritten.name;
			delete rewritten.call_id;
			delete rewritten.namespace;
		}
	}

	return rewriteExecWaitToolCall(rewritten);
}

export function rewriteResponseForCodex(value, mapping, usageOptions) {
	const rewritten = rewriteValueForClient(value, mapping, { includeNamespace: true });
	if (!isObject(rewritten)) return rewritten;
	if (isObject(rewritten.usage)) {
		const usage = normalizeUsage(rewritten.usage, usageOptions);
		if (usage) rewritten.usage = usage;
		else delete rewritten.usage;
	}
	if (isObject(rewritten.response) && isObject(rewritten.response.usage)) {
		const usage = normalizeUsage(rewritten.response.usage, usageOptions);
		if (usage) rewritten.response.usage = usage;
		else delete rewritten.response.usage;
	}

	return rewritten;
}

export function rewriteChatCompletionForClient(value, mapping) {
	return rewriteValueForClient(value, mapping, { includeNamespace: false });
}

function parseSseBlock(raw) {
	const lines = raw.split(/\r?\n/u);
	const dataLines = [];
	let eventName = null;
	for (const line of lines) {
		if (line.startsWith('event:')) eventName = line.slice(6).trim();
		if (line.startsWith('data:')) dataLines.push(line.slice(5).replace(/^ /u, ''));
	}
	if (dataLines.length === 0) return { raw, eventName, data: null, dataText: null };

	const dataText = dataLines.join('\n');
	if (dataText.trim() === '[DONE]') return { raw, eventName, data: null, dataText, doneToken: true };
	try {
		return { raw, eventName, data: JSON.parse(dataText), dataText };
	} catch {
		return { raw, eventName, data: null, dataText, invalidJson: true };
	}
}

function encodeSse(eventName, data) {
	return `event: ${eventName}\ndata: ${JSON.stringify(data)}\n\n`;
}

function responseEvent(type, responseId, data = {}) {
	return { type, response_id: responseId, ...data };
}

function responseItemName(name, mapping) {
	const original = resolveOriginal(name, mapping);

	return original ? { name: original.name, namespace: original.namespace } : { name: name ?? '' };
}

function customCallItem({ id, callId, name, argumentsJson, status = 'completed' }, mapping) {
	if (!isAdaptedCustomTool(name, mapping)) return null;
	const input = customInputFromArguments(argumentsJson);
	if (input === null) {
		throw new BridgeResponseError('tool_call_invalid', 'Adapted custom tool call has invalid input.');
	}

	return { type: 'custom_tool_call', id, call_id: callId, name, input, status };
}

function hasMappedNamePrefix(name, mapping) {
	if (typeof name !== 'string' || name === '') return false;
	const candidates = [
		...(mapping?.fullToOriginal?.keys?.() ?? []),
		...(mapping?.uniqueBareToOriginal?.keys?.() ?? []),
		...(mapping?.namespaceOnlyToOriginal?.keys?.() ?? [])
	];

	return candidates.some((candidate) => candidate !== name && candidate.startsWith(name));
}

function completionMessageText(message) {
	if (typeof message?.content === 'string') return message.content;
	if (!Array.isArray(message?.content)) return '';

	return message.content
		.map((part) => (typeof part === 'string' ? part : typeof part?.text === 'string' ? part.text : ''))
		.join('');
}

function completionToolCalls(message) {
	if (Array.isArray(message?.tool_calls)) return message.tool_calls;
	if (isObject(message?.function_call)) return [{ type: 'function', function: message.function_call, legacy: true }];

	return [];
}

function newResponseId(prefix = 'resp_cliproxy') {
	return `${prefix}_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
}

function validateToolCall({ id, name, argumentsJson, outputIndex }) {
	if (typeof id !== 'string' || id.trim() === '') {
		throw new BridgeResponseError('tool_call_invalid', `Tool call at output index ${outputIndex} is missing an id.`);
	}
	if (typeof name !== 'string' || name.trim() === '') {
		throw new BridgeResponseError('tool_call_invalid', `Tool call at output index ${outputIndex} is missing a function name.`);
	}
	if (typeof argumentsJson !== 'string' || argumentsJson.trim() === '') {
		throw new BridgeResponseError('tool_call_invalid', `Tool call at output index ${outputIndex} is missing arguments.`);
	}
	try {
		JSON.parse(argumentsJson);
	} catch {
		throw new BridgeResponseError('tool_call_invalid', `Tool call at output index ${outputIndex} has invalid arguments.`);
	}
}

export function convertChatCompletionToResponse(completion, mapping, usageOptions) {
	if (!isObject(completion) || !Array.isArray(completion.choices)) {
		throw new BridgeResponseError('invalid_chat_completion', 'CLIProxyAPI returned an invalid Chat Completions response.');
	}

	const responseId = typeof completion.id === 'string' && completion.id.trim() ? completion.id : newResponseId();
	const output = [];
	let generatedCallOrdinal = 0;
	for (const choice of completion.choices) {
		const message = isObject(choice?.message) ? choice.message : {};
		const text = completionMessageText(message);
		if (text !== '') {
			output.push({
				type: 'message',
				id: `${responseId}_message_${choice?.index ?? output.length}`,
				role: 'assistant',
				status: 'completed',
				content: [{ type: 'output_text', text }]
			});
		}

		const calls = completionToolCalls(message);
		if (choice?.finish_reason === 'tool_calls' && calls.length === 0) {
			throw new BridgeResponseError('tool_call_invalid', 'CLIProxyAPI finished with tool_calls but supplied no tool call.');
		}
		for (const call of calls) {
			const safeCall = call ?? {};
			const functionData = isObject(safeCall.function) ? safeCall.function : {};
			const id =
				typeof safeCall.id === 'string' && safeCall.id
					? safeCall.id
					: safeCall.legacy === true
						? `${responseId}_call_${generatedCallOrdinal++}`
						: safeCall.id;
			const name = functionData.name;
			const argumentsJson = functionData.arguments;
			validateToolCall({ id, name, argumentsJson, outputIndex: output.length });
			const customItem = customCallItem({ id, callId: id, name, argumentsJson }, mapping);
			if (customItem) {
				output.push(rewriteExecWaitToolCall(customItem));
				continue;
			}
			const restored = responseItemName(name, mapping);
			output.push(
				rewriteExecWaitToolCall({
					type: 'function_call',
					id,
					call_id: id,
					...restored,
					arguments: canonicalizeArguments(argumentsJson),
					status: 'completed'
				})
			);
		}
	}
	const usage = normalizeUsage(completion.usage, usageOptions);

	return applyUnresolvedYieldWait(
		{
			id: responseId,
			object: 'response',
			status: 'completed',
			...(typeof completion.model === 'string' ? { model: completion.model } : {}),
			...(typeof completion.created === 'number' ? { created_at: completion.created } : {}),
			output,
			output_count: output.length,
			...(usage ? { usage } : {})
		},
		{
			yieldCellId: usageOptions?.yieldCellId,
			waitToolAvailable: usageOptions?.waitToolAvailable,
			logger: usageOptions?.logger,
			model: usageOptions?.model ?? completion.model
		}
	);
}

function rewriteJsonResponse(parsed, protocol, mapping, usageOptions) {
	if (protocol === 'responses' && Array.isArray(parsed.choices)) {
		return convertChatCompletionToResponse(parsed, mapping, usageOptions);
	}
	if (protocol === 'responses') {
		return applyUnresolvedYieldWait(rewriteResponseForCodex(parsed, mapping, usageOptions), usageOptions);
	}

	return rewriteChatCompletionForClient(parsed, mapping);
}

class RewritingSseTransform extends Transform {
	constructor(mapping, rewrite) {
		super();
		this.mapping = mapping;
		this.rewrite = rewrite;
		this.buffer = '';
		this.decoder = new StringDecoder('utf8');
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
			callback();
		} catch (error) {
			callback(error);
		}
	}

	drainFrames(flush = false) {
		while (true) {
			const separator = /\r?\n\r?\n/u.exec(this.buffer);
			if (!separator) break;
			const raw = this.buffer.slice(0, separator.index + separator[0].length);
			this.buffer = this.buffer.slice(separator.index + separator[0].length);
			this.rewriteFrame(parseSseBlock(raw));
		}
		if (flush && this.buffer.length > 0) {
			this.rewriteFrame(parseSseBlock(this.buffer));
			this.buffer = '';
		}
	}

	rewriteFrame(frame) {
		if (!frame.data || frame.invalidJson || frame.doneToken) {
			this.push(Buffer.from(frame.raw, 'utf8'));

			return;
		}
		const rewritten = this.rewrite(frame.data, this.mapping);
		this.push(Buffer.from(encodeSse(frame.eventName ?? rewritten.type ?? '', rewritten), 'utf8'));
	}
}

export function createSseTransform(mapping, usageOptions) {
	return new RewritingSseTransform(mapping, (value, currentMapping) =>
		rewriteResponseForCodex(value, currentMapping, usageOptions)
	);
}

function createChatSseTransform(mapping) {
	return new RewritingSseTransform(mapping, rewriteChatCompletionForClient);
}

class ChatCompletionsResponsesTransform extends Transform {
	constructor(options = {}) {
		super();
		this.mapping = options.mapping ?? emptyMapping();
		this.logger = options.logger ?? console;
		this.model = typeof options.model === 'string' ? options.model : 'unknown';
		this.decoder = new StringDecoder('utf8');
		this.buffer = '';
		this.mode = 'unknown';
		this.responseId = newResponseId();
		this.started = false;
		this.completed = false;
		this.failed = false;
		this.yieldCellId =
			typeof options.yieldCellId === 'string' && options.yieldCellId.trim() !== '' ? options.yieldCellId.trim() : null;
		this.waitToolAvailable = options.waitToolAvailable === true;
		this.nativeEmittedToolCall = false;
		this.messages = new Map();
		this.tools = new Map();
		this.output = [];
		this.finishReasons = new Map();
		this.nativeCustomItems = new Set();
		this.usage = null;
		this.usageOptions = { maxInputTokens: options.maxInputTokens, logger: this.logger, model: this.model };
		this.anonymousToolOrdinal = 0;
	}

	emitRaw(raw) {
		this.push(Buffer.from(raw, 'utf8'));
	}

	emitEvent(type, data) {
		this.emitRaw(encodeSse(type, data));
	}

	startResponse(data) {
		if (this.started) return;
		this.started = true;
		if (typeof data.id === 'string' && data.id.trim()) this.responseId = data.id;
		this.emitEvent(
			'response.created',
			responseEvent('response.created', this.responseId, {
				response: { id: this.responseId, object: 'response', status: 'in_progress', output: [] }
			})
		);
	}

	messageKey(choiceIndex) {
		return String(choiceIndex ?? 0);
	}

	startMessage(choiceIndex) {
		const key = this.messageKey(choiceIndex);
		let state = this.messages.get(key);
		if (state) return state;

		const item = {
			type: 'message',
			id: `${this.responseId}_message_${key}`,
			role: 'assistant',
			status: 'in_progress',
			content: []
		};
		state = { item, outputIndex: this.output.length, text: '', contentStarted: false, done: false };
		this.messages.set(key, state);
		this.output.push(item);
		this.emitEvent(
			'response.output_item.added',
			responseEvent('response.output_item.added', this.responseId, { output_index: state.outputIndex, item })
		);

		return state;
	}

	appendMessageText(choiceIndex, delta) {
		if (typeof delta !== 'string' || delta === '') return;
		const state = this.startMessage(choiceIndex);
		state.text += delta;
		if (!state.contentStarted) {
			state.contentStarted = true;
			this.emitEvent(
				'response.content_part.added',
				responseEvent('response.content_part.added', this.responseId, {
					output_index: state.outputIndex,
					content_index: 0,
					part: { type: 'output_text', text: '' }
				})
			);
		}
		this.emitEvent(
			'response.output_text.delta',
			responseEvent('response.output_text.delta', this.responseId, {
				output_index: state.outputIndex,
				content_index: 0,
				delta
			})
		);
	}

	toolKey(choiceIndex, toolCall, ordinal) {
		if (toolCall?.index !== undefined && toolCall?.index !== null) return `${choiceIndex ?? 0}:${toolCall.index}`;
		if (typeof toolCall?.id === 'string' && toolCall.id !== '') return `${choiceIndex ?? 0}:id:${toolCall.id}`;

		return `${choiceIndex ?? 0}:anonymous:${ordinal ?? this.anonymousToolOrdinal++}`;
	}

	findToolById(id) {
		if (typeof id !== 'string' || id === '') return null;
		for (const state of this.tools.values()) {
			if (state.upstreamId === id) return state;
		}

		return null;
	}

	getTool(choiceIndex, toolCall, ordinal) {
		const existingById = this.findToolById(toolCall?.id);
		if (existingById) return existingById;

		const key = this.toolKey(choiceIndex, toolCall, ordinal);
		let state = this.tools.get(key);
		if (state) return state;

		state = {
			key,
			upstreamId: null,
			name: null,
			arguments: '',
			argumentDeltas: [],
			item: null,
			outputIndex: null,
			emitted: false,
			done: false,
			legacy: toolCall?.legacy === true
		};
		this.tools.set(key, state);

		return state;
	}

	mergeScalar(state, property, value) {
		if (typeof value !== 'string' || value === '') return true;
		if (state[property] === null || state[property] === '') {
			state[property] = value;

			return true;
		}
		if (state[property] === value || state[property].startsWith(value)) return true;
		if (value.startsWith(state[property])) {
			state[property] = value;

			return true;
		}

		this.fail(state);

		return false;
	}

	activateTool(state) {
		if (
			state.emitted ||
			this.failed ||
			!state.upstreamId ||
			!state.name ||
			hasMappedNamePrefix(state.name, this.mapping) ||
			(state.arguments === '' && /[_:-]$/u.test(state.upstreamId))
		) {
			return;
		}
		const restored = responseItemName(state.name, this.mapping);
		state.custom = isAdaptedCustomTool(state.name, this.mapping);
		state.outputIndex = this.output.length;
		state.item = state.custom
			? {
					type: 'custom_tool_call',
					id: state.upstreamId,
					call_id: state.upstreamId,
					name: state.name,
					input: '',
					status: 'in_progress'
				}
			: {
					type: 'function_call',
					id: state.upstreamId,
					call_id: state.upstreamId,
					...restored,
					arguments: '',
					status: 'in_progress'
				};
		state.emitted = true;
		this.output.push(state.item);
		this.emitEvent(
			'response.output_item.added',
			responseEvent('response.output_item.added', this.responseId, { output_index: state.outputIndex, item: state.item })
		);
		for (const delta of state.argumentDeltas) this.emitToolArgumentDelta(state, delta);
	}

	emitToolArgumentDelta(state, delta) {
		if (!state.emitted || typeof delta !== 'string' || delta === '') return;
		if (state.custom) return;
		this.emitEvent(
			'response.function_call_arguments.delta',
			responseEvent('response.function_call_arguments.delta', this.responseId, {
				output_index: state.outputIndex,
				item_id: state.item.id,
				call_id: state.item.call_id,
				delta
			})
		);
	}

	appendToolArguments(state, delta) {
		if (typeof delta !== 'string' || delta === '' || this.failed) return;
		state.arguments += delta;
		state.argumentDeltas.push(delta);
		this.emitToolArgumentDelta(state, delta);
	}

	mergeCompleteArguments(state, argumentsJson) {
		if (typeof argumentsJson !== 'string') return;
		if (state.arguments === argumentsJson) return;
		if (argumentsJson.startsWith(state.arguments)) {
			this.appendToolArguments(state, argumentsJson.slice(state.arguments.length));

			return;
		}
		if (state.arguments.startsWith(argumentsJson)) return;
		this.fail(state);
	}

	processToolCall(choiceIndex, toolCall, ordinal, completionOnly = false) {
		if (this.failed || !isObject(toolCall)) return;
		const state = this.getTool(choiceIndex, toolCall, ordinal);
		const functionData = isObject(toolCall.function) ? toolCall.function : {};
		const generatedId = toolCall.legacy === true ? `${this.responseId}_call_${state.key.replace(/[^A-Za-z0-9_]/gu, '_')}` : null;
		if (!this.mergeScalar(state, 'upstreamId', toolCall.id ?? generatedId)) return;
		if (!this.mergeScalar(state, 'name', functionData.name)) return;
		this.activateTool(state);
		if (completionOnly) this.mergeCompleteArguments(state, functionData.arguments);
		else this.appendToolArguments(state, functionData.arguments);
	}

	processChatMessage(choiceIndex, message) {
		const text = completionMessageText(message);
		if (text !== '') {
			const state = this.messages.get(this.messageKey(choiceIndex));
			const current = state?.text ?? '';
			if (current === '') this.appendMessageText(choiceIndex, text);
			else if (text === current) {
				// Final Chat Completions messages commonly repeat already streamed text.
			} else if (text.startsWith(current)) this.appendMessageText(choiceIndex, text.slice(current.length));
			else this.fail(null);
		}
		for (let index = 0; index < completionToolCalls(message).length; index += 1) {
			this.processToolCall(choiceIndex, completionToolCalls(message)[index], index, true);
			if (this.failed) return;
		}
	}

	processChatFrame(data) {
		this.mode = 'chat';
		this.startResponse(data);
		if (data.usage) this.usage = normalizeUsage(data.usage, this.usageOptions);
		for (const choice of data.choices ?? []) {
			const choiceIndex = choice?.index ?? 0;
			if (typeof choice?.finish_reason === 'string' && choice.finish_reason !== '') {
				this.finishReasons.set(choiceIndex, choice.finish_reason);
			}
			this.appendMessageText(choiceIndex, choice?.delta?.content);
			if (isObject(choice?.delta?.function_call)) {
				this.processToolCall(choiceIndex, { type: 'function', function: choice.delta.function_call, legacy: true }, 0);
			}
			for (let index = 0; index < (choice?.delta?.tool_calls ?? []).length; index += 1) {
				this.processToolCall(choiceIndex, choice.delta.tool_calls[index], index);
				if (this.failed) return;
			}
			if (isObject(choice?.message)) this.processChatMessage(choiceIndex, choice.message);
			if (this.failed) return;
		}
	}

	finishMessages() {
		for (const state of this.messages.values()) {
			if (state.done) continue;
			state.done = true;
			if (state.contentStarted) {
				this.emitEvent(
					'response.output_text.done',
					responseEvent('response.output_text.done', this.responseId, {
						output_index: state.outputIndex,
						content_index: 0,
						text: state.text
					})
				);
				this.emitEvent(
					'response.content_part.done',
					responseEvent('response.content_part.done', this.responseId, {
						output_index: state.outputIndex,
						content_index: 0,
						part: { type: 'output_text', text: state.text }
					})
				);
			}
			state.item.content = state.contentStarted ? [{ type: 'output_text', text: state.text }] : [];
			state.item.status = 'completed';
			this.emitEvent(
				'response.output_item.done',
				responseEvent('response.output_item.done', this.responseId, { output_index: state.outputIndex, item: state.item })
			);
		}
	}

	finishTools() {
		for (const state of this.tools.values()) {
			if (state.done) continue;
			if (!state.emitted || !state.upstreamId || !state.name) {
				this.fail(state);

				return;
			}
			try {
				validateToolCall({
					id: state.upstreamId,
					name: state.name,
					argumentsJson: state.arguments,
					outputIndex: state.outputIndex
				});
			} catch {
				this.fail(state);

				return;
			}
			state.done = true;
			if (state.custom) {
				const input = customInputFromArguments(state.arguments);
				if (input === null) {
					this.fail(state);

					return;
				}
				state.item.input = input;
			} else {
				state.item.arguments = canonicalizeArguments(state.arguments);
			}
			state.item.status = 'completed';
			if (state.custom) {
				this.emitEvent(
					'response.custom_tool_call_input.done',
					responseEvent('response.custom_tool_call_input.done', this.responseId, {
						output_index: state.outputIndex,
						item_id: state.item.id,
						input: state.item.input
					})
				);
			} else {
				this.emitEvent(
					'response.function_call_arguments.done',
					responseEvent('response.function_call_arguments.done', this.responseId, {
						output_index: state.outputIndex,
						item_id: state.item.id,
						call_id: state.item.call_id,
						name: state.item.name,
						...(state.item.namespace ? { namespace: state.item.namespace } : {}),
						arguments: state.item.arguments
					})
				);
			}
			this.emitEvent(
				'response.output_item.done',
				responseEvent('response.output_item.done', this.responseId, { output_index: state.outputIndex, item: state.item })
			);
		}
	}

	finishChat() {
		if (this.completed || this.failed) return;
		if ([...this.finishReasons.values()].includes('tool_calls') && this.tools.size === 0) {
			this.fail(null);

			return;
		}
		this.finishMessages();
		if (this.tools.size === 0 && this.yieldCellId && this.waitToolAvailable) {
			this.processToolCall(
				0,
				{
					id: `${this.responseId}_wait_yield`,
					type: 'function',
					function: {
						name: 'wait',
						arguments: JSON.stringify({ cell_id: this.yieldCellId, yield_time_ms: SYNTHETIC_WAIT_YIELD_MS })
					}
				},
				0,
				true
			);
			logInjectedWait(this.logger, this.model, this.yieldCellId);
		}
		this.finishTools();
		if (this.failed) return;

		this.completed = true;
		this.emitEvent(
			'response.completed',
			responseEvent('response.completed', this.responseId, {
				response: {
					id: this.responseId,
					object: 'response',
					status: 'completed',
					output: this.output,
					output_count: this.output.length,
					...(this.usage ? { usage: this.usage } : {})
				}
			})
		);
	}

	finishNativeResponse(completed) {
		if (this.completed || this.failed) return;
		const rewritten = isObject(completed) ? completed : {};
		const existingOutput =
			isObject(rewritten.response) && Array.isArray(rewritten.response.output)
				? rewritten.response.output
				: Array.isArray(rewritten.output)
					? rewritten.output
					: [];
		const hasTool = this.nativeEmittedToolCall || outputHasToolCall(existingOutput);
		const next = applyUnresolvedYieldWait(rewritten, {
			yieldCellId: hasTool ? null : this.yieldCellId,
			waitToolAvailable: this.waitToolAvailable,
			logger: this.logger,
			model: this.model
		});
		const response = isObject(next.response) ? next.response : next;
		const output = Array.isArray(response.output) ? response.output : [];
		if (output.length > existingOutput.length) {
			const waitItem = output.at(-1);
			const outputIndex = output.length - 1;
			const responseId = typeof response.id === 'string' && response.id ? response.id : this.responseId;
			this.emitEvent(
				'response.output_item.added',
				responseEvent('response.output_item.added', responseId, {
					output_index: outputIndex,
					item: { ...waitItem, status: 'in_progress', arguments: '' }
				})
			);
			this.emitEvent(
				'response.function_call_arguments.done',
				responseEvent('response.function_call_arguments.done', responseId, {
					output_index: outputIndex,
					item_id: waitItem.id,
					call_id: waitItem.call_id,
					name: waitItem.name,
					arguments: waitItem.arguments
				})
			);
			this.emitEvent(
				'response.output_item.done',
				responseEvent('response.output_item.done', responseId, { output_index: outputIndex, item: waitItem })
			);
		}
		this.completed = true;
		this.emitEvent('response.completed', {
			...next,
			type: 'response.completed',
			response: {
				...response,
				id: response.id ?? this.responseId,
				object: response.object ?? 'response',
				status: 'completed',
				output,
				output_count: output.length
			}
		});
	}

	fail(state) {
		if (this.failed || this.completed) return;
		this.failed = true;
		const tool = state?.name ? responseItemName(state.name, this.mapping).name : '(unknown)';
		const outputIndex = state?.outputIndex ?? -1;
		const inputBytes = Buffer.byteLength(state?.arguments ?? '', 'utf8');
		this.logger.error?.(
			`[${SERVICE_NAME}] invalid tool call model=${this.model} output_index=${outputIndex} tool=${tool} input_bytes=${inputBytes}`
		);
		this.emitEvent('response.failed', {
			type: 'response.failed',
			response_id: this.responseId,
			error: { code: 'cliproxy_tool_call_parse_error', message: 'CLIProxyAPI returned an invalid tool call.' }
		});
	}

	processFrame(frame) {
		if (this.failed) return;
		if (frame.doneToken) {
			if (this.mode === 'chat') {
				this.finishChat();
				if (!this.failed) this.emitRaw(frame.raw);
			} else {
				this.emitRaw(frame.raw);
			}

			return;
		}
		if (frame.invalidJson) {
			if (this.mode === 'chat') this.fail(null);
			else this.emitRaw(frame.raw);

			return;
		}
		if (!frame.data) {
			this.emitRaw(frame.raw);

			return;
		}
		if (Array.isArray(frame.data.choices)) {
			this.processChatFrame(frame.data);

			return;
		}
		if (this.mode === 'chat') {
			if (frame.data.type === 'response.completed') this.finishChat();
			else this.emitRaw(frame.raw);

			return;
		}
		const nativeItem = frame.data.item;
		if (
			(frame.data.type === 'response.output_item.added' || frame.data.type === 'response.output_item.done') &&
			nativeItem?.type === 'function_call' &&
			isAdaptedCustomTool(nativeItem.name, this.mapping) &&
			typeof nativeItem.id === 'string'
		) {
			this.nativeCustomItems.add(nativeItem.id);
		}
		if (frame.data.type === 'response.function_call_arguments.delta' && this.nativeCustomItems.has(frame.data.item_id)) {
			return;
		}
		if (frame.data.type === 'response.function_call_arguments.done' && this.nativeCustomItems.has(frame.data.item_id)) {
			const input = customInputFromArguments(frame.data.arguments);
			if (input === null) {
				this.fail({ name: 'custom', arguments: frame.data.arguments, outputIndex: frame.data.output_index });

				return;
			}
			this.emitEvent('response.custom_tool_call_input.done', {
				...frame.data,
				type: 'response.custom_tool_call_input.done',
				input,
				arguments: undefined,
				call_id: undefined,
				name: undefined
			});

			return;
		}

		const rewritten = rewriteResponseForCodex(frame.data, this.mapping);
		const itemType = rewritten.item?.type;
		if (
			(rewritten.type === 'response.output_item.added' || rewritten.type === 'response.output_item.done') &&
			(itemType === 'function_call' || itemType === 'custom_tool_call')
		) {
			this.nativeEmittedToolCall = true;
		}
		if (rewritten.type === 'response.completed') {
			this.finishNativeResponse(rewritten);

			return;
		}
		this.emitEvent(frame.eventName ?? rewritten.type ?? '', rewritten);
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
			if (this.mode === 'chat' && !this.completed && !this.failed) this.fail(null);
			callback();
		} catch (error) {
			callback(error);
		}
	}

	drainFrames(flush = false) {
		while (true) {
			const separator = /\r?\n\r?\n/u.exec(this.buffer);
			if (!separator) break;
			const raw = this.buffer.slice(0, separator.index + separator[0].length);
			this.buffer = this.buffer.slice(separator.index + separator[0].length);
			this.processFrame(parseSseBlock(raw));
			if (this.failed) return;
		}
		if (flush && this.buffer.trim() !== '') {
			this.processFrame(parseSseBlock(this.buffer));
			this.buffer = '';
		}
	}
}

export function createResponsesSseTransform(options = {}) {
	return new ChatCompletionsResponsesTransform(options);
}

function copyHeaders(headers, { transformed = false } = {}) {
	const copied = {};
	for (const [name, value] of Object.entries(headers)) {
		const lowerName = name.toLowerCase();
		if (HOP_BY_HOP_HEADERS.has(lowerName)) continue;
		if (transformed && (lowerName === 'content-length' || lowerName === 'content-encoding')) continue;
		copied[name] = value;
	}

	return copied;
}

function sendError(response, statusCode, code, message) {
	if (response.headersSent || response.destroyed || response.writableEnded) {
		if (!response.destroyed) response.destroy();

		return;
	}
	const body = JSON.stringify({ error: { message, type: 'cliproxy_bridge_error', code } });
	response.writeHead(statusCode, {
		'content-type': 'application/json; charset=utf-8',
		'content-length': Buffer.byteLength(body)
	});
	response.end(body);
}

async function readBody(stream, maxBodyBytes) {
	const chunks = [];
	let totalBytes = 0;
	for await (const chunk of stream) {
		totalBytes += chunk.length;
		if (totalBytes > maxBodyBytes) {
			throw new BridgeRequestError(413, 'request_body_too_large', `Request exceeds the ${maxBodyBytes} byte bridge limit.`);
		}
		chunks.push(chunk);
	}

	return Buffer.concat(chunks);
}

function requestProtocol(request, targetUrl) {
	if (request.method !== 'POST') return null;
	if (targetUrl.pathname === '/v1/responses') return 'responses';
	if (targetUrl.pathname === '/v1/chat/completions') return 'chat';

	return null;
}

function isExpectedDisconnect(error, state, response) {
	return [
		state.downstreamDisconnected,
		response.destroyed,
		response.writableEnded,
		EXPECTED_DISCONNECT_CODES.has(error?.code)
	].some(Boolean);
}

function proxyUpstreamResponse(upstreamResponse, response, options) {
	const { mapping, protocol, model, logger, maxInputTokens, state, yieldCellId, waitToolAvailable } = options;
	const usageOptions = { maxInputTokens, logger, model, yieldCellId, waitToolAvailable };
	const contentType = String(upstreamResponse.headers['content-type'] ?? '').toLowerCase();
	const contentEncoding = String(upstreamResponse.headers['content-encoding'] ?? '').toLowerCase();
	const canTransform = protocol !== null && (!contentEncoding || contentEncoding === 'identity');
	const transformedHeaders = copyHeaders(upstreamResponse.headers, { transformed: true });

	if (canTransform && contentType.includes('text/event-stream')) {
		if (!response.destroyed && !response.writableEnded) {
			response.writeHead(upstreamResponse.statusCode ?? 502, transformedHeaders);
		}
		const transform =
			protocol === 'responses'
				? createResponsesSseTransform({ mapping, model, logger, maxInputTokens, yieldCellId, waitToolAvailable })
				: createChatSseTransform(mapping);
		pipeline(upstreamResponse, transform, response, (error) => {
			if (!error || isExpectedDisconnect(error, state, response)) return;
			logger.error?.(`[${SERVICE_NAME}] pipeline error code=${error.code ?? 'unknown'}`);
			if (!response.destroyed && !response.writableEnded) response.destroy(error);
		});

		return;
	}

	if (canTransform && contentType.includes('application/json')) {
		const chunks = [];
		upstreamResponse.on('data', (chunk) => chunks.push(chunk));
		upstreamResponse.on('end', () => {
			if (state.downstreamDisconnected || response.destroyed || response.writableEnded) return;
			const originalBody = Buffer.concat(chunks);
			let body = originalBody;
			let statusCode = upstreamResponse.statusCode ?? 502;
			try {
				const parsed = JSON.parse(originalBody.toString('utf8'));
				const rewritten = rewriteJsonResponse(parsed, protocol, mapping, usageOptions);
				body = Buffer.from(JSON.stringify(rewritten));
			} catch (error) {
				if (error instanceof BridgeResponseError) {
					statusCode = 502;
					body = Buffer.from(
						JSON.stringify({
							error: {
								message: 'CLIProxyAPI returned an invalid tool call.',
								type: 'cliproxy_bridge_error',
								code: error.code
							}
						})
					);
				}
			}
			const headers = { ...transformedHeaders, 'content-length': body.length };
			response.writeHead(statusCode, headers);
			response.end(body);
		});
		upstreamResponse.on('error', (error) => {
			if (!isExpectedDisconnect(error, state, response) && !response.destroyed && !response.writableEnded) {
				logger.error?.(`[${SERVICE_NAME}] upstream response error code=${error.code ?? 'unknown'}`);
				response.destroy(error);
			}
		});

		return;
	}

	if (!response.destroyed && !response.writableEnded) {
		response.writeHead(upstreamResponse.statusCode ?? 502, copyHeaders(upstreamResponse.headers));
	}
	pipeline(upstreamResponse, response, (error) => {
		if (!error || isExpectedDisconnect(error, state, response)) return;
		logger.error?.(`[${SERVICE_NAME}] pipeline error code=${error.code ?? 'unknown'}`);
		if (!response.destroyed && !response.writableEnded) response.destroy(error);
	});
}

function proxyRequest({
	request,
	response,
	targetUrl,
	headers,
	body,
	mapping,
	protocol,
	model,
	onUpstreamAbort,
	logger,
	maxInputTokens,
	yieldCellId,
	waitToolAvailable
}) {
	const transport = targetUrl.protocol === 'https:' ? https : http;
	const startedAt = Date.now();
	const state = { downstreamDisconnected: false, aborted: false };
	const upstreamRequest = transport.request(
		{
			protocol: targetUrl.protocol,
			hostname: targetUrl.hostname,
			port: targetUrl.port,
			method: request.method,
			path: `${targetUrl.pathname}${targetUrl.search}`,
			headers
		},
		(upstreamResponse) => {
			response.once('finish', () => {
				logger.log?.(
					`[${SERVICE_NAME}] ${request.method} ${targetUrl.pathname} -> ${upstreamResponse.statusCode} (${Date.now() - startedAt}ms)`
				);
			});
			proxyUpstreamResponse(upstreamResponse, response, {
				mapping,
				protocol,
				model,
				logger,
				maxInputTokens,
				state,
				yieldCellId,
				waitToolAvailable
			});
		}
	);

	const abortUpstream = () => {
		if (state.aborted) return;
		state.aborted = true;
		state.downstreamDisconnected = true;
		if (!upstreamRequest.destroyed) upstreamRequest.destroy();
		onUpstreamAbort?.();
	};
	request.once('aborted', abortUpstream);
	request.socket.once('close', () => {
		if (!response.writableEnded) abortUpstream();
	});
	response.once('close', () => {
		if (!response.writableEnded) abortUpstream();
	});

	upstreamRequest.on('error', (error) => {
		if (isExpectedDisconnect(error, state, response)) return;
		logger.error?.(`[${SERVICE_NAME}] upstream request error code=${error.code ?? 'unknown'}`);
		sendError(response, 502, 'upstream_unavailable', 'CLIProxyAPI is unavailable.');
	});

	if (body) {
		upstreamRequest.end(body);

		return;
	}
	pipeline(request, upstreamRequest, (error) => {
		if (error && !upstreamRequest.destroyed) upstreamRequest.destroy(error);
	});
}

export function createBridgeServer(options = {}) {
	const upstreamUrl = new URL(options.upstreamUrl ?? DEFAULT_UPSTREAM);
	const buildId = options.buildId ?? 'development';
	const maxBodyBytes = options.maxBodyBytes ?? DEFAULT_MAX_BODY_BYTES;
	const maxInputTokens = options.maxInputTokens ?? DEFAULT_MAX_INPUT_TOKENS;
	const logger = options.logger ?? console;

	return http.createServer(async (request, response) => {
		const requestUrl = new URL(request.url ?? '/', 'http://bridge.local');
		if (request.method === 'GET' && requestUrl.pathname === '/_bridge/health') {
			const body = JSON.stringify({
				status: 'ok',
				service: SERVICE_NAME,
				pid: process.pid,
				build_id: buildId,
				upstream: upstreamUrl.origin
			});
			response.writeHead(200, {
				'content-type': 'application/json; charset=utf-8',
				'content-length': Buffer.byteLength(body)
			});
			response.end(body);

			return;
		}

		const targetUrl = new URL(`${requestUrl.pathname}${requestUrl.search}`, upstreamUrl);
		const protocol = requestProtocol(request, targetUrl);
		const headers = copyHeaders(request.headers, { transformed: protocol !== null });
		headers.host = targetUrl.host;
		if (protocol !== null) headers['accept-encoding'] = 'identity';

		let body;
		let mapping = emptyMapping();
		let model = 'unknown';
		let yieldCellId = null;
		let waitToolAvailable = false;
		try {
			if (protocol !== null) {
				const requestBody = await readBody(request, maxBodyBytes);
				let parsed;
				try {
					parsed = JSON.parse(requestBody.toString('utf8'));
				} catch {
					throw new BridgeRequestError(400, 'invalid_json', 'OpenAI request body is not valid JSON.');
				}
				const flattened = flattenOpenAiRequest(parsed);
				mapping = flattened.mapping;
				model = typeof flattened.body.model === 'string' ? flattened.body.model : model;
				yieldCellId = unresolvedYieldCellId(parsed);
				waitToolAvailable = requestHasWaitTool(parsed);
				body = Buffer.from(JSON.stringify(flattened.body));
				headers['content-length'] = body.length;
			}
		} catch (error) {
			if (error instanceof BridgeRequestError) {
				sendError(response, error.statusCode, error.code, error.message);

				return;
			}
			sendError(response, 400, 'invalid_request', 'OpenAI request is invalid.');

			return;
		}

		proxyRequest({
			request,
			response,
			targetUrl,
			headers,
			body,
			mapping,
			protocol,
			model,
			onUpstreamAbort: options.onUpstreamAbort,
			logger,
			maxInputTokens,
			yieldCellId,
			waitToolAvailable
		});
	});
}

function parsePositiveInteger(value, fallback) {
	const parsed = Number.parseInt(value ?? '', 10);

	return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function isMainModule() {
	if (!process.argv[1]) return false;

	return pathToFileURL(resolve(process.argv[1])).href === import.meta.url;
}

if (isMainModule()) {
	const host = process.env.CLIPROXY_BRIDGE_HOST ?? DEFAULT_HOST;
	const port = parsePositiveInteger(process.env.CLIPROXY_BRIDGE_PORT, DEFAULT_PORT);
	const upstreamUrl = process.env.CLIPROXY_UPSTREAM ?? DEFAULT_UPSTREAM;
	const buildId = process.env.CLIPROXY_BRIDGE_BUILD_ID ?? 'development';
	const maxBodyBytes = parsePositiveInteger(process.env.CLIPROXY_BRIDGE_MAX_BODY_BYTES, DEFAULT_MAX_BODY_BYTES);
	const maxInputTokens = parsePositiveInteger(process.env.CLIPROXY_BRIDGE_MAX_INPUT_TOKENS, DEFAULT_MAX_INPUT_TOKENS);
	const server = createBridgeServer({ upstreamUrl, buildId, maxBodyBytes, maxInputTokens });

	server.listen(port, host, () => {
		console.log(`[${SERVICE_NAME}] listening on http://${host}:${port}; upstream=${upstreamUrl}; build=${buildId}`);
	});
	server.on('error', (error) => {
		console.error(`[${SERVICE_NAME}] fatal: ${error.message}`);
		process.exitCode = 1;
	});
	for (const signal of ['SIGINT', 'SIGTERM']) {
		process.once(signal, () => server.close(() => process.exit(0)));
	}
}

export { BridgeRequestError, SERVICE_NAME };
