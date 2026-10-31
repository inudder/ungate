import { randomUUID } from 'node:crypto';
import http from 'node:http';
import https from 'node:https';
import { pipeline, Transform } from 'node:stream';
import { StringDecoder } from 'node:string_decoder';
import { fileURLToPath } from 'node:url';

import { messageFromAgentMessage } from './codex-agent-messages.mjs';
import { createToolsCacheWriter } from './codex-tools-schema-cache.mjs';
import { adaptDeepSeekRequest, createDeepSeekStreamAdapter, restoreDeepSeekResponse } from './deepseek-responses-adapter.mjs';
import { flattenMimoResponsesRequest, restoreMimoResponsesValue } from './mimo-responses-namespace.mjs';
import { createMimoResponsesStreamAdapter } from './mimo-responses-stream-adapter.mjs';

export { orderDeepSeekToolHistory } from './deepseek-responses-adapter.mjs';

const SERVICE_NAME = 'codex-model-shell-router';
const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_PORT = 8319;
const DEFAULT_MAX_BODY_BYTES = 128 * 1024 * 1024;
const DEFAULT_SSE_KEEPALIVE_MS = 5000;
const MIMO_RESPONSES_ADAPTER = 'mimo-textual-tools';
const DEEPSEEK_RESPONSES_ADAPTER = 'deepseek-responses';
const SSE_KEEPALIVE_COMMENT = ': codex-model-shell-router keep-alive\n\n';
const SSE_KEEPALIVE_HEADERS = {
	'cache-control': 'no-cache',
	'content-type': 'text/event-stream; charset=utf-8',
	connection: 'keep-alive'
};
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

export class ShellRouterRequestError extends Error {
	constructor(statusCode, code, message) {
		super(message);
		this.statusCode = statusCode;
		this.code = code;
	}
}

function parsePositiveInteger(value, fallback) {
	const parsed = Number.parseInt(value ?? '', 10);

	return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function copyHeaders(headers, options = {}) {
	const copied = {};
	for (const [name, value] of Object.entries(headers)) {
		if (
			!HOP_BY_HOP_HEADERS.has(name.toLowerCase()) &&
			!(options.stripContentLength && name.toLowerCase() === 'content-length') &&
			value !== undefined
		) {
			copied[name] = value;
		}
	}

	return copied;
}

function sendError(response, statusCode, code, message) {
	if (response.headersSent) {
		response.destroy();

		return;
	}

	const body = JSON.stringify({ error: { message, type: 'codex_model_shell_router_error', code } });
	response.writeHead(statusCode, {
		'content-type': 'application/json; charset=utf-8',
		'content-length': Buffer.byteLength(body)
	});
	response.end(body);
}

function sendStreamError(response, code, message) {
	if (response.destroyed || response.writableEnded) return;
	response.end(`event: error\ndata: ${JSON.stringify({ type: 'error', sequence_number: 0, code, message, param: null })}\n\n`);
}

function diagnosticId(value) {
	return typeof value === 'string' && /^[a-zA-Z0-9_.:-]{1,160}$/u.test(value) ? value : undefined;
}

const SSE_LINE_HEAD_CHARS = 256;
const SSE_TERMINAL_FAILURES = new Map([
	['response.failed', 'response_failed'],
	['response.incomplete', 'response_incomplete'],
	['error', 'stream_error']
]);

// OmniRoute can append a synthetic missing-marker error after a valid token-limit
// terminal. Keep the incomplete result and every genuine upstream failure.
class OpenCodeTerminalGuard extends Transform {
	constructor() {
		super();
		this.decoder = new StringDecoder('utf8');
		this.pending = '';
		this.tokenLimitReached = false;
	}

	_transform(chunk, encoding, callback) {
		this.pending = (this.pending + this.decoder.write(chunk)).replace(/\r\n/g, '\n');
		let end;
		while ((end = this.pending.indexOf('\n\n')) >= 0) {
			const block = this.pending.slice(0, end + 2);
			this.pending = this.pending.slice(end + 2);
			let duplicate = false;
			try {
				const data = block
					.split('\n')
					.filter((line) => line.startsWith('data:'))
					.map((line) => line.slice(5).trimStart())
					.join('\n');
				const event = JSON.parse(data);
				duplicate =
					this.tokenLimitReached &&
					event.type === 'response.failed' &&
					event.response?.error?.code === 'server_error' &&
					event.response.error.message === 'Upstream stream ended without a terminal marker';
				if (event.type === 'response.incomplete' && event.response?.incomplete_details?.reason === 'max_output_tokens')
					this.tokenLimitReached = true;
			} catch {
				/* Non-JSON SSE comments and markers pass through. */
			}
			if (!duplicate) this.push(block);
		}
		if (this.pending.length > 1024 * 1024) {
			this.push(this.pending);
			this.pending = '';
		}
		callback();
	}

	_flush(callback) {
		this.push(this.pending + this.decoder.end());
		callback();
	}
}

// Passes an unadapted SSE stream through unchanged and records whether it reached
// response.completed. Codex closes the socket right after that event, so without this a
// finished turn was logged as 499 client_disconnected. Only each line's head is retained.
export class SseCompletionObserver extends Transform {
	constructor({ onFailure } = {}) {
		super();
		this.decoder = new StringDecoder('utf8');
		this.lineHead = '';
		this.completed = false;
		this.failed = false;
		this.onFailure = onFailure;
	}

	_transform(chunk, _encoding, callback) {
		this.scan(this.decoder.write(chunk));
		callback(null, chunk);
	}

	_flush(callback) {
		this.scan(this.decoder.end());
		this.inspectLine();
		callback();
	}

	scan(text) {
		let start = 0;
		for (let newline = text.indexOf('\n'); newline >= 0; newline = text.indexOf('\n', start)) {
			this.appendLineHead(text.slice(start, newline));
			this.inspectLine();
			start = newline + 1;
		}
		this.appendLineHead(text.slice(start));
	}

	appendLineHead(fragment) {
		if (this.lineHead.length < SSE_LINE_HEAD_CHARS) {
			this.lineHead += fragment.slice(0, SSE_LINE_HEAD_CHARS - this.lineHead.length);
		}
	}

	inspectLine() {
		const match = /^(?:event:[ \t]*([\w.]+)|data:[ \t]*\{[ \t]*"type"[ \t]*:[ \t]*"([\w.]+)")/u.exec(this.lineHead);
		this.lineHead = '';
		const type = match?.[1] ?? match?.[2];
		if (type === 'response.completed') {
			this.completed = true;
		} else if (SSE_TERMINAL_FAILURES.has(type) && !this.failed) {
			this.failed = true;
			this.onFailure?.(SSE_TERMINAL_FAILURES.get(type));
		}
	}
}

function startSseKeepAlive(response, intervalMs) {
	let timer = null;
	let headerTimer = null;
	let waitingForDrain = false;
	let stopped = false;
	let active = false;

	const clearTimer = () => {
		if (timer !== null) {
			clearTimeout(timer);
			timer = null;
		}
	};
	const schedule = () => {
		if (!active || stopped || waitingForDrain || response.destroyed || response.writableEnded) return;
		timer = setTimeout(() => {
			timer = null;
			if (stopped || response.destroyed || response.writableEnded) return;
			if (!response.write(SSE_KEEPALIVE_COMMENT, 'utf8')) {
				waitingForDrain = true;
				response.once('drain', onDrain);

				return;
			}
			schedule();
		}, intervalMs);
	};
	const onDrain = () => {
		waitingForDrain = false;
		schedule();
	};
	const activate = () => {
		if (stopped) return;
		active = true;
		if (headerTimer !== null) {
			clearTimeout(headerTimer);
			headerTimer = null;
		}
		schedule();
	};
	const forceHeaders = () => {
		headerTimer = null;
		if (stopped || response.headersSent || response.destroyed || response.writableEnded) return;
		response.writeHead(200, SSE_KEEPALIVE_HEADERS);
		activate();
		if (!response.write(SSE_KEEPALIVE_COMMENT, 'utf8')) {
			waitingForDrain = true;
			response.once('drain', onDrain);
		}
	};
	const onFinish = () => stop();
	const onClose = () => stop();
	const stop = () => {
		if (stopped) return;
		stopped = true;
		clearTimer();
		if (headerTimer !== null) {
			clearTimeout(headerTimer);
			headerTimer = null;
		}
		response.removeListener('drain', onDrain);
		response.removeListener('finish', onFinish);
		response.removeListener('close', onClose);
	};

	response.once('finish', onFinish);
	response.once('close', onClose);
	headerTimer = setTimeout(forceHeaders, intervalMs);

	return { activate, stop };
}

async function readBody(stream, maxBodyBytes) {
	const chunks = [];
	let totalBytes = 0;
	for await (const chunk of stream) {
		totalBytes += chunk.length;
		if (totalBytes > maxBodyBytes) {
			throw new ShellRouterRequestError(
				413,
				'request_body_too_large',
				`Request exceeds the ${maxBodyBytes} byte shell-router limit.`
			);
		}
		chunks.push(chunk);
	}

	return Buffer.concat(chunks);
}

// Codex marks some tool arguments with encrypted: true. That flag is not JSON Schema,
// and Gemini's function declaration converter rejects it as an unknown field.
function stripEncryptedSchemaKeywords(value) {
	if (Array.isArray(value)) {
		for (const item of value) stripEncryptedSchemaKeywords(item);

		return;
	}
	if (!value || typeof value !== 'object') return;
	if (typeof value.encrypted === 'boolean') delete value.encrypted;
	for (const child of Object.values(value)) stripEncryptedSchemaKeywords(child);
}

function routeRejectsEncryptedSchemaKeyword(route) {
	return /gemini/i.test(route.upstreamModel);
}

// OpenCode's Go gateway returns HTTP 503 "Endpoint is unavailable" for a whole
// conversation once its history contains two tool calls that share one call_id,
// and the poisoned conversation keeps failing on every later request. The model
// occasionally reuses an earlier call id, so rename the later call and its
// output consistently instead of forwarding an ambiguous history. Deterministic
// per history order: the same input always gets the same names.
function normalizeOpenCodeToolCallIds(body) {
	if (!Array.isArray(body.input)) return;
	const seen = new Set();
	const renames = [];
	for (const item of body.input) {
		if (!item || typeof item !== 'object' || typeof item.call_id !== 'string' || item.call_id === '') continue;
		const type = typeof item.type === 'string' ? item.type : '';
		if (type.endsWith('_output')) {
			const index = renames.findIndex((entry) => entry.from === item.call_id);
			if (index >= 0) {
				item.call_id = renames[index].to;
				renames.splice(index, 1);
			}
			continue;
		}
		if (!seen.has(item.call_id)) {
			seen.add(item.call_id);
			continue;
		}
		const base = item.call_id.slice(0, 48);
		let suffix = 1;
		let candidate = `${base}_${suffix}`;
		while (seen.has(candidate)) {
			suffix++;
			candidate = `${base}_${suffix}`;
		}
		seen.add(candidate);
		renames.push({ from: item.call_id, to: candidate });
		item.call_id = candidate;
	}
}

function prepareArgonResponsesRequest(body, outputBudget = 32768) {
	// Avoid relying on the upstream default: the observed incomplete response had
	// exactly 8192 output tokens. Preserve any explicit caller budget.
	if (body.max_output_tokens == null && body.max_tokens == null && body.max_completion_tokens == null) {
		body.max_output_tokens = outputBudget;
	}
	if (!Array.isArray(body.input)) return;
	// OmniRoute's Chat conversion turns agent_message into assistant history or
	// drops it when it carries encrypted_content. Normalize it before that hop.
	body.input = body.input.map((item) => (item?.type === 'agent_message' ? messageFromAgentMessage(item) : item));
	const last = body.input.findLast((item) => item?.type !== 'reasoning');
	if (last?.role !== 'assistant' || (last.type && last.type !== 'message') || last.tool_calls?.length) return;
	// Codex retries an incomplete response with the partial assistant message in
	// history. Gemini rejects a final model turn; retain it and request continuation
	// explicitly. Tool calls/results remain untouched and incompletes stay failures.
	body.input.push({
		role: 'user',
		content: [
			{
				type: 'input_text',
				text: 'Continue from where the previous response stopped. Do not repeat completed work. If a tool call was interrupted, issue a complete tool call.'
			}
		]
	});
}

function normalizeRoute(route) {
	if (!route || typeof route !== 'object') {
		throw new Error('A shell router route must be an object.');
	}

	const clientModel = String(route.clientModel ?? '').trim();
	const upstreamModel = String(route.upstreamModel ?? '').trim();
	const upstreamBaseUrl = String(route.upstreamBaseUrl ?? '').trim();
	const apiKey = String(route.apiKey ?? '').trim();
	const responsesAdapter = String(route.responsesAdapter ?? '').trim() || null;
	if (route.parallelToolCalls !== undefined && typeof route.parallelToolCalls !== 'boolean') {
		throw new Error('parallelToolCalls must be a Boolean when specified.');
	}
	if (!clientModel || !upstreamModel || !upstreamBaseUrl || !apiKey) {
		throw new Error('Each shell router route needs clientModel, upstreamModel, upstreamBaseUrl and apiKey.');
	}

	let parsedUrl;
	try {
		parsedUrl = new URL(upstreamBaseUrl);
	} catch {
		throw new Error(`Invalid upstream URL for model shell '${clientModel}'.`);
	}
	if (parsedUrl.protocol !== 'http:' && parsedUrl.protocol !== 'https:') {
		throw new Error(`Unsupported upstream protocol for model shell '${clientModel}'.`);
	}
	if (responsesAdapter && ![MIMO_RESPONSES_ADAPTER, DEEPSEEK_RESPONSES_ADAPTER].includes(responsesAdapter)) {
		throw new Error(`Unsupported Responses stream adapter '${responsesAdapter}' for model shell '${clientModel}'.`);
	}

	return {
		clientModel,
		upstreamModel,
		upstreamUrl: parsedUrl,
		apiKey,
		responsesAdapter,
		parallelToolCalls: route.parallelToolCalls
	};
}

function normalizeRoutes(routes) {
	const byClientModel = new Map();
	for (const route of routes ?? []) {
		const normalized = normalizeRoute(route);
		const key = normalized.clientModel.toLowerCase();
		if (byClientModel.has(key)) {
			throw new Error(`Duplicate model shell '${normalized.clientModel}'.`);
		}
		byClientModel.set(key, normalized);
	}
	if (byClientModel.size === 0) {
		throw new Error('At least one shell router route is required.');
	}

	return byClientModel;
}

function proxyRequest({
	request,
	response,
	targetUrl,
	headers,
	body,
	responsesAdapter,
	model,
	clientModel,
	streaming,
	logger,
	sseKeepAliveMs,
	namespaceMapping,
	onComplete,
	requestId,
	startedAt
}) {
	const transport = targetUrl.protocol === 'https:' ? https : http;
	const keepAlive = streaming && responsesAdapter === MIMO_RESPONSES_ADAPTER ? startSseKeepAlive(response, sseKeepAliveMs) : null;
	headers['x-request-id'] = requestId;
	let upstreamStatus = 502;
	let upstreamRequestId;
	let errorCategory = null;
	let streamAdapter = null;
	let logged = false;
	const logResult = (disconnected = false) => {
		if (logged) return;
		logged = true;
		const responseCompleted = streamAdapter?.completed === true && !streamAdapter.failed && !errorCategory;
		const disconnectedBeforeCompletion = disconnected && !responseCompleted;
		const status = disconnectedBeforeCompletion ? 499 : upstreamStatus;
		const endpoint = ['/v1/responses', '/v1/chat/completions'].includes(targetUrl.pathname) ? targetUrl.pathname : '/other';
		logger(
			`[${SERVICE_NAME}] ${request.method} ${endpoint} -> ${status} (${Date.now() - startedAt}ms) ${JSON.stringify({
				timestamp: new Date().toISOString(),
				client_model: clientModel,
				model,
				upstream: targetUrl.origin,
				request_id: requestId,
				upstream_request_id: upstreamRequestId,
				status,
				response_completed: streamAdapter ? responseCompleted : null,
				error_category: disconnectedBeforeCompletion ? (errorCategory ?? 'client_disconnected') : errorCategory
			})}`
		);
	};
	response.once('finish', () => {
		logResult();
		onComplete();
	});
	response.once('close', () => {
		if (!response.writableEnded) logResult(true);
		onComplete();
	});
	let downstreamDisconnected = false;

	request.setTimeout(600000);

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
			upstreamStatus = upstreamResponse.statusCode ?? 502;
			upstreamRequestId = diagnosticId(upstreamResponse.headers['x-request-id']);
			if (upstreamStatus >= 400) errorCategory = `upstream_http_${upstreamStatus}`;
			const contentType = String(upstreamResponse.headers['content-type'] ?? '').toLowerCase();
			const adapterEnabled =
				[MIMO_RESPONSES_ADAPTER, DEEPSEEK_RESPONSES_ADAPTER].includes(responsesAdapter) &&
				(upstreamResponse.statusCode ?? 500) >= 200 &&
				(upstreamResponse.statusCode ?? 500) < 300 &&
				contentType.includes('text/event-stream');
			if (!adapterEnabled) keepAlive?.stop();
			// A heartbeat may have committed SSE headers before upstream admission finished.
			// A late HTTP/JSON response must never be appended as bare JSON to that stream.
			if (response.headersSent && !adapterEnabled && keepAlive) {
				if (upstreamStatus < 400) {
					errorCategory = 'upstream_protocol_error';
					sendStreamError(response, errorCategory, 'The streaming upstream returned an unexpected response format.');
					upstreamResponse.destroy();

					return;
				}
				void readBody(upstreamResponse, 64 * 1024).then(
					(errorBody) => {
						let upstreamError;
						try {
							upstreamError = JSON.parse(errorBody.toString('utf8')).error;
						} catch {
							/* Non-JSON errors use the status below. */
						}
						const upstreamCode = diagnosticId(upstreamError?.code);
						if (upstreamCode) errorCategory = upstreamCode;
						let code = upstreamCode ?? `upstream_http_${upstreamStatus}`;
						if (upstreamStatus === 429) code = 'rate_limit_exceeded';
						else if (upstreamStatus >= 500) code = 'server_error';
						const message =
							typeof upstreamError?.message === 'string'
								? upstreamError.message.slice(0, 2048)
								: `Upstream returned HTTP ${upstreamStatus}.`;
						sendStreamError(response, code, message);
					},
					() =>
						sendStreamError(
							response,
							'server_error',
							`Upstream returned HTTP ${upstreamStatus}; its error body could not be read.`
						)
				);

				return;
			}
			const rewriteJson = namespaceMapping && contentType.includes('application/json');
			if (rewriteJson) {
				const chunks = [];
				upstreamResponse.on('data', (chunk) => chunks.push(chunk));
				upstreamResponse.on('end', () => {
					const originalBody = Buffer.concat(chunks);
					let bodyBuffer = originalBody;
					try {
						const parsed = JSON.parse(originalBody.toString('utf8'));
						if (upstreamStatus >= 400) errorCategory = diagnosticId(parsed.error?.code) ?? errorCategory;
						const restored =
							responsesAdapter === DEEPSEEK_RESPONSES_ADAPTER
								? restoreDeepSeekResponse(parsed, namespaceMapping)
								: restoreMimoResponsesValue(parsed, namespaceMapping);
						bodyBuffer = Buffer.from(JSON.stringify(restored));
					} catch {
						if (responsesAdapter === DEEPSEEK_RESPONSES_ADAPTER) {
							sendError(response, 502, 'deepseek_exec_parse_error', 'DeepSeek returned invalid exec arguments or JSON.');

							return;
						}
						// Preserve malformed or non-JSON upstream payloads verbatim.
					}
					const responseHeaders = copyHeaders(upstreamResponse.headers, { stripContentLength: true });
					responseHeaders['content-length'] = bodyBuffer.length;
					if (!response.headersSent) response.writeHead(upstreamResponse.statusCode ?? 502, responseHeaders);
					response.end(bodyBuffer);
				});
				upstreamResponse.on('error', (error) => {
					if (!response.destroyed && !response.writableEnded) response.destroy(error);
				});

				return;
			}
			if (!response.headersSent) {
				response.writeHead(
					upstreamResponse.statusCode ?? 502,
					copyHeaders(upstreamResponse.headers, { stripContentLength: adapterEnabled })
				);
			}
			if (adapterEnabled) keepAlive?.activate();
			else keepAlive?.stop();
			const observePassthrough =
				!adapterEnabled && upstreamStatus >= 200 && upstreamStatus < 300 && contentType.includes('text/event-stream');
			streamAdapter =
				adapterEnabled && responsesAdapter === DEEPSEEK_RESPONSES_ADAPTER
					? createDeepSeekStreamAdapter(namespaceMapping)
					: adapterEnabled
						? createMimoResponsesStreamAdapter({
								model,
								namespaceMapping,
								onFailure: (code) => {
									errorCategory = code;
								},
								logger: (message) => console.error(`[${SERVICE_NAME}] ${message}`)
							})
						: observePassthrough
							? new SseCompletionObserver({
									onFailure: (code) => {
										errorCategory = code;
									}
								})
							: null;
			const onPipelineError = (error) => {
				keepAlive?.stop();
				const expectedDisconnect = [
					response.destroyed,
					response.writableEnded,
					error?.code === 'ERR_STREAM_UNABLE_TO_PIPE',
					error?.code === 'ERR_STREAM_PREMATURE_CLOSE'
				].some(Boolean);
				if (error && !expectedDisconnect) {
					console.error(`[${SERVICE_NAME}] pipeline_error ${diagnosticId(error.code) ?? 'stream_error'}`);
					response.destroy(error);
				}
			};
			try {
				if (!response.destroyed && !response.writableEnded) {
					const transforms = [];
					if (observePassthrough && model.startsWith('opencode-go-api/')) transforms.push(new OpenCodeTerminalGuard());
					if (streamAdapter) transforms.push(streamAdapter);
					const streamPipeline = pipeline(upstreamResponse, ...transforms, response, onPipelineError);
					void streamPipeline;
				}
			} catch (error) {
				onPipelineError(error);
			}
		}
	);

	upstreamRequest.setTimeout(600000);

	const abortUpstream = () => {
		downstreamDisconnected = true;
		keepAlive?.stop();
		if (!upstreamRequest.destroyed) {
			upstreamRequest.destroy(new Error('downstream client disconnected'));
		}
	};

	request.once('aborted', abortUpstream);
	response.once('close', () => {
		if (!response.writableEnded) abortUpstream();
	});
	request.socket.once('close', () => {
		if (!response.writableEnded && !response.destroyed) {
			abortUpstream();
		}
	});

	upstreamRequest.on('error', (error) => {
		keepAlive?.stop();
		if (downstreamDisconnected || response.destroyed || response.writableEnded) return;
		errorCategory = diagnosticId(error.code) ?? 'upstream_unavailable';
		if (!response.destroyed && !response.writableEnded) {
			if (response.headersSent) sendStreamError(response, 'server_error', 'Mapped upstream is unavailable.');
			else sendError(response, 502, 'upstream_unavailable', 'Mapped upstream is unavailable.');
		}
	});

	upstreamRequest.end(body);
}

export function createShellRouterServer(options = {}) {
	const makeSnapshot = (config) => ({
		routes: normalizeRoutes(config.routes),
		cacheTools: createToolsCacheWriter(config.toolsCachePath, () => console.error(`[${SERVICE_NAME}] tools_cache_error`))
	});
	let snapshot = options.routes ? makeSnapshot(options) : null;
	let revision = options.revision ?? null;
	let activeRequests = 0;
	let drainUntil = 0;
	let commandRevision = null;
	let errorRevision = null;
	let configError = null;
	const buildId = options.buildId ?? 'development';
	const maxBodyBytes = options.maxBodyBytes ?? DEFAULT_MAX_BODY_BYTES;
	const sseKeepAliveMs = parsePositiveInteger(options.sseKeepAliveMs, DEFAULT_SSE_KEEPALIVE_MS);
	const logger = options.logger ?? ((message) => console.log(message));

	const server = http.createServer(async (request, response) => {
		const requestUrl = new URL(request.url ?? '/', 'http://shell-router.local');
		const draining = drainUntil > Date.now();
		if (request.method === 'GET' && requestUrl.pathname === '/_shell-router/health') {
			const body = JSON.stringify({
				status: snapshot ? 'ok' : 'not_ready',
				service: SERVICE_NAME,
				pid: process.pid,
				build_id: buildId,
				route_models: snapshot ? [...snapshot.routes.values()].map((route) => route.clientModel) : [],
				config_revision: revision,
				command_revision: commandRevision,
				error_revision: errorRevision,
				config_error: configError,
				active_requests: activeRequests,
				draining
			});
			response.writeHead(200, {
				'content-type': 'application/json; charset=utf-8',
				'content-length': Buffer.byteLength(body)
			});
			response.end(body);

			return;
		}

		if (request.method === 'GET' && requestUrl.pathname === '/v1/models') {
			if (!snapshot) {
				sendError(response, 503, 'router_not_ready', 'The shell router is not configured.');

				return;
			}
			const body = JSON.stringify({
				object: 'list',
				data: [...snapshot.routes.values()].map((route) => ({
					id: route.clientModel,
					object: 'model',
					created: 0,
					owned_by: SERVICE_NAME
				}))
			});
			response.writeHead(200, {
				'content-type': 'application/json; charset=utf-8',
				'content-length': Buffer.byteLength(body)
			});
			response.end(body);

			return;
		}

		if (request.method !== 'POST') {
			sendError(response, 405, 'method_not_allowed', 'Only POST requests and local discovery endpoints are supported.');

			return;
		}
		const startedAt = Date.now();
		const requestId = diagnosticId(request.headers['x-request-id']) ?? randomUUID();
		const endpoint = ['/v1/responses', '/v1/chat/completions'].includes(requestUrl.pathname) ? requestUrl.pathname : '/other';
		const logLocalFailure = (status, category) =>
			logger(
				`[${SERVICE_NAME}] POST ${endpoint} -> ${status} (${Date.now() - startedAt}ms) ${JSON.stringify({
					timestamp: new Date().toISOString(),
					model: null,
					request_id: requestId,
					status,
					error_category: category
				})}`
			);
		if (!snapshot || draining) {
			const category = draining ? 'router_draining' : 'router_not_ready';
			logLocalFailure(503, category);
			sendError(
				response,
				503,
				category,
				draining ? 'The shell router is temporarily draining requests.' : 'The shell router is not configured.'
			);

			return;
		}

		// Pin the complete snapshot as soon as the request is admitted. A later
		// configuration change cannot reroute a request whose body is still arriving.
		const requestSnapshot = snapshot;
		activeRequests++;
		let counted = true;
		const finishRequest = () => {
			if (counted) {
				counted = false;
				activeRequests--;
			}
		};
		response.once('finish', finishRequest);
		response.once('close', finishRequest);

		try {
			const requestBody = await readBody(request, maxBodyBytes);
			let body;
			try {
				body = JSON.parse(requestBody.toString('utf8'));
			} catch {
				throw new ShellRouterRequestError(400, 'invalid_json', 'Request body is not valid JSON.');
			}
			const requestedModel = typeof body.model === 'string' ? body.model.trim() : '';
			const route = requestSnapshot.routes.get(requestedModel.toLowerCase());
			if (!route) {
				const requestedModelLabel = requestedModel === '' ? '(empty)' : requestedModel;
				throw new ShellRouterRequestError(400, 'unknown_model_shell', `Unknown Codex model shell '${requestedModelLabel}'.`);
			}

			if (requestUrl.pathname === '/v1/responses') void requestSnapshot.cacheTools(body.tools, route.upstreamModel);
			let namespaceMapping = null;
			if (route.responsesAdapter === MIMO_RESPONSES_ADAPTER && requestUrl.pathname === '/v1/responses') {
				const flattened = flattenMimoResponsesRequest(body);
				body = flattened.body;
				namespaceMapping = flattened.mapping;
			}
			if (route.responsesAdapter === DEEPSEEK_RESPONSES_ADAPTER && requestUrl.pathname === '/v1/responses') {
				const adapted = adaptDeepSeekRequest(body);
				body = adapted.body;
				namespaceMapping = adapted.mapping;
			}

			body.model = route.upstreamModel;
			if (requestUrl.pathname === '/v1/responses' && route.parallelToolCalls !== undefined) {
				body.parallel_tool_calls = route.parallelToolCalls;
			}
			if (routeRejectsEncryptedSchemaKeyword(route)) {
				stripEncryptedSchemaKeywords(body.tools);
			}
			if (requestUrl.pathname === '/v1/responses' && /(?:^|\/)gemini-4-argon$/i.test(route.upstreamModel)) {
				prepareArgonResponsesRequest(body, route.upstreamModel.startsWith('opencode-go-api/') ? 65536 : 32768);
			}
			if (requestUrl.pathname === '/v1/responses' && route.upstreamModel.startsWith('opencode-go-api/')) {
				normalizeOpenCodeToolCallIds(body);
			}
			const upstreamBody = Buffer.from(JSON.stringify(body));
			const targetUrl = new URL(`${requestUrl.pathname}${requestUrl.search}`, route.upstreamUrl);
			const headers = copyHeaders(request.headers);
			if (route.upstreamModel.startsWith('opencode-go-api/') && !headers['x-opencode-session']) {
				const session = headers.session_id ?? headers['session-id'] ?? headers['x-session-id'];
				if (typeof session === 'string' && session.trim() && session.length <= 256 && !/[\u0000-\u001f\u007f]/u.test(session)) {
					headers['x-opencode-session'] = session.trim();
				}
			}
			headers.host = targetUrl.host;
			headers.authorization = `Bearer ${route.apiKey}`;
			headers['content-length'] = upstreamBody.length;
			delete headers['content-encoding'];
			if (
				namespaceMapping ||
				(route.responsesAdapter === MIMO_RESPONSES_ADAPTER && requestUrl.pathname === '/v1/responses' && body.stream === true)
			) {
				headers['accept-encoding'] = 'identity';
			}

			response.removeListener('finish', finishRequest);
			response.removeListener('close', finishRequest);
			proxyRequest({
				request,
				response,
				targetUrl,
				headers,
				body: upstreamBody,
				model: route.upstreamModel,
				clientModel: route.clientModel,
				streaming: requestUrl.pathname === '/v1/responses' && body.stream === true,
				logger,
				responsesAdapter: route.responsesAdapter && requestUrl.pathname === '/v1/responses' ? route.responsesAdapter : null,
				sseKeepAliveMs,
				namespaceMapping,
				onComplete: finishRequest,
				requestId,
				startedAt
			});
		} catch (error) {
			finishRequest();
			if (error instanceof ShellRouterRequestError) {
				logLocalFailure(error.statusCode, error.code);
				sendError(response, error.statusCode, error.code, error.message);

				return;
			}
			logLocalFailure(400, 'invalid_request');
			sendError(response, 400, 'invalid_request', error instanceof Error ? error.message : String(error));
		}
	});

	server.shellRouter = {
		prepare: makeSnapshot,
		activate(next, nextRevision) {
			snapshot = next;
			revision = nextRevision;
			configError = null;
			errorRevision = null;
		},
		command(action, nextRevision, leaseMs = 60000) {
			if (action === 'drain') drainUntil = Date.now() + Math.min(Math.max(leaseMs, 1000), 120000);
			else if (action === 'resume') drainUntil = 0;
			else throw new Error('invalid_command');
			commandRevision = nextRevision;
			configError = null;
			errorRevision = null;
		},
		fail(nextRevision, code) {
			errorRevision = nextRevision;
			configError = code;
		}
	};

	return server;
}

function routesFromEnvironment() {
	const rawRoutes = process.env.CODEX_SHELL_ROUTER_ROUTES_JSON;
	if (!rawRoutes) {
		throw new Error('CODEX_SHELL_ROUTER_ROUTES_JSON is required.');
	}
	const parsed = JSON.parse(rawRoutes);
	if (!Array.isArray(parsed.routes)) {
		throw new Error('CODEX_SHELL_ROUTER_ROUTES_JSON.routes must be an array.');
	}

	return parsed.routes.map((route) => ({
		clientModel: route.clientModel,
		upstreamModel: route.upstreamModel,
		upstreamBaseUrl: route.upstreamBaseUrl,
		apiKey: process.env[route.apiKeyEnv],
		responsesAdapter: route.responsesAdapter,
		parallelToolCalls: route.parallelToolCalls
	}));
}

function isMainModule() {
	return process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
}

if (isMainModule()) {
	const host = process.env.CODEX_SHELL_ROUTER_HOST ?? DEFAULT_HOST;
	const port = parsePositiveInteger(process.env.CODEX_SHELL_ROUTER_PORT, DEFAULT_PORT);
	const buildId = process.env.CODEX_SHELL_ROUTER_BUILD_ID ?? 'development';
	const maxBodyBytes = parsePositiveInteger(process.env.CODEX_SHELL_ROUTER_MAX_BODY_BYTES, DEFAULT_MAX_BODY_BYTES);
	const server = createShellRouterServer({
		routes: routesFromEnvironment(),
		toolsCachePath: process.env.CODEX_SHELL_ROUTER_TOOLS_CACHE_PATH,
		buildId,
		maxBodyBytes
	});
	server.listen(port, host, () => {
		console.log(`[${SERVICE_NAME}] listening on http://${host}:${port}; build=${buildId}`);
	});
	server.on('error', (error) => {
		console.error(`[${SERVICE_NAME}] fatal: ${error.message}`);
		process.exitCode = 1;
	});
	for (const signal of ['SIGINT', 'SIGTERM']) {
		process.once(signal, () => server.close(() => process.exit(0)));
	}
	process.on('uncaughtException', () => {
		console.error(`[${SERVICE_NAME}] uncaught_exception`);
		process.exit(1);
	});
	process.on('unhandledRejection', () => {
		console.error(`[${SERVICE_NAME}] unhandled_rejection`);
		process.exit(1);
	});
}

export { MIMO_RESPONSES_ADAPTER, SERVICE_NAME };
