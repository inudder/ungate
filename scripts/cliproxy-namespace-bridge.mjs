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

class BridgeRequestError extends Error {
	constructor(statusCode, code, message) {
		super(message);
		this.statusCode = statusCode;
		this.code = code;
	}
}

function isObject(value) {
	return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function makeFlatToolName(namespace, name) {
	return `${namespace.replace(/__+$/u, '')}__${name}`;
}

function cloneFunctionTool(innerTool, flatName) {
	const flattened = { ...innerTool, type: 'function', name: flatName };
	const parameters = innerTool.parameters ?? innerTool.input_schema ?? innerTool.inputSchema;

	delete flattened.namespace;
	delete flattened.input_schema;
	delete flattened.inputSchema;
	if (parameters !== undefined) {
		flattened.parameters = parameters;
	}

	return flattened;
}

function addBareCandidate(candidates, name, original) {
	const current = candidates.get(name);
	if (!current) {
		candidates.set(name, original);

		return;
	}
	if (current.namespace !== original.namespace || current.name !== original.name) {
		candidates.set(name, null);
	}
}

export function flattenResponsesRequest(body) {
	if (!isObject(body)) {
		throw new BridgeRequestError(400, 'invalid_request_body', 'Responses request body must be a JSON object.');
	}

	const tools = Array.isArray(body.tools) ? body.tools : [];
	const directNames = new Set(
		tools.filter((tool) => isObject(tool) && tool.type !== 'namespace' && typeof tool.name === 'string').map((tool) => tool.name)
	);
	const usedNames = new Set(directNames);
	const fullToOriginal = new Map();
	const namespaceToolToFlat = new Map();
	const bareCandidates = new Map();
	const flattenedTools = [];

	for (const tool of tools) {
		if (!isObject(tool) || tool.type !== 'namespace') {
			flattenedTools.push(tool);
			continue;
		}

		const namespace = tool.name;
		const innerTools = Array.isArray(tool.tools) ? tool.tools : tool.functions;
		if (typeof namespace !== 'string' || namespace.length === 0 || !Array.isArray(innerTools)) {
			throw new BridgeRequestError(400, 'invalid_namespace_tool', 'Namespace tools require a non-empty name and a tools array.');
		}

		for (const innerTool of innerTools) {
			if (!isObject(innerTool) || typeof innerTool.name !== 'string' || innerTool.name.length === 0) {
				throw new BridgeRequestError(
					400,
					'invalid_namespace_tool',
					`Namespace '${namespace}' contains a tool without a valid name.`
				);
			}

			const flatName = makeFlatToolName(namespace, innerTool.name);
			if (usedNames.has(flatName)) {
				throw new BridgeRequestError(400, 'tool_name_collision', `Flattened tool name '${flatName}' collides with another tool.`);
			}

			const original = { namespace, name: innerTool.name };
			usedNames.add(flatName);
			fullToOriginal.set(flatName, original);
			namespaceToolToFlat.set(`${namespace}\u0000${innerTool.name}`, flatName);
			addBareCandidate(bareCandidates, innerTool.name, original);
			flattenedTools.push(cloneFunctionTool(innerTool, flatName));
		}
	}

	for (const directName of directNames) {
		if (bareCandidates.has(directName)) {
			bareCandidates.set(directName, null);
		}
	}

	const uniqueBareToOriginal = new Map([...bareCandidates.entries()].filter(([, original]) => original !== null));
	const mapping = { fullToOriginal, namespaceToolToFlat, uniqueBareToOriginal };
	const rewritten = { ...body };

	if (Array.isArray(body.tools)) {
		rewritten.tools = flattenedTools;
	}
	if (body.input !== undefined) {
		rewritten.input = rewriteValueForUpstream(body.input, mapping);
	}
	if (body.tool_choice !== undefined) {
		rewritten.tool_choice = rewriteToolChoiceForUpstream(body.tool_choice, mapping);
	}

	return { body: rewritten, mapping };
}

function rewriteValueForUpstream(value, mapping) {
	if (Array.isArray(value)) {
		return value.map((item) => rewriteValueForUpstream(item, mapping));
	}
	if (!isObject(value)) {
		return value;
	}

	const rewritten = {};
	for (const [key, child] of Object.entries(value)) {
		rewritten[key] = rewriteValueForUpstream(child, mapping);
	}

	if (rewritten.type === 'function_call' && typeof rewritten.namespace === 'string' && typeof rewritten.name === 'string') {
		const flatName = mapping.namespaceToolToFlat.get(`${rewritten.namespace}\u0000${rewritten.name}`);
		if (flatName) {
			rewritten.name = flatName;
			delete rewritten.namespace;
		}
	}

	return rewritten;
}

function rewriteToolChoiceForUpstream(toolChoice, mapping) {
	if (!isObject(toolChoice)) {
		return toolChoice;
	}

	const rewritten = { ...toolChoice };
	if (typeof rewritten.namespace === 'string' && typeof rewritten.name === 'string') {
		const flatName = mapping.namespaceToolToFlat.get(`${rewritten.namespace}\u0000${rewritten.name}`);
		if (flatName) {
			rewritten.type = 'function';
			rewritten.name = flatName;
			delete rewritten.namespace;
		}
	}

	if (
		isObject(rewritten.function) &&
		typeof rewritten.function.namespace === 'string' &&
		typeof rewritten.function.name === 'string'
	) {
		const flatName = mapping.namespaceToolToFlat.get(`${rewritten.function.namespace}\u0000${rewritten.function.name}`);
		if (flatName) {
			rewritten.function = { ...rewritten.function, name: flatName };
			delete rewritten.function.namespace;
		}
	}

	return rewritten;
}

export function canonicalizeArguments(argumentsJson) {
	if (typeof argumentsJson !== 'string' || argumentsJson.length === 0) {
		return argumentsJson;
	}
	try {
		return JSON.stringify(JSON.parse(argumentsJson));
	} catch {
		return argumentsJson;
	}
}

export function rewriteResponseForCodex(value, mapping) {
	if (Array.isArray(value)) {
		return value.map((item) => rewriteResponseForCodex(item, mapping));
	}
	if (!isObject(value)) {
		return value;
	}

	const rewritten = {};
	for (const [key, child] of Object.entries(value)) {
		rewritten[key] = rewriteResponseForCodex(child, mapping);
	}

	if (typeof rewritten.arguments === 'string') {
		if (rewritten.type === 'function_call' || rewritten.type === 'response.function_call_arguments.done') {
			rewritten.arguments = canonicalizeArguments(rewritten.arguments);
		}
	}

	if (rewritten.type === 'function_call' && typeof rewritten.name === 'string') {
		const original = mapping.fullToOriginal.get(rewritten.name) ?? mapping.uniqueBareToOriginal.get(rewritten.name);
		if (original) {
			rewritten.name = original.name;
			rewritten.namespace = original.namespace;
		}
	}

	return rewritten;
}

function transformSseBlock(block, mapping) {
	const lines = block.split(/\r?\n/u);
	const dataIndexes = [];
	const dataParts = [];

	for (let index = 0; index < lines.length; index += 1) {
		if (!lines[index].startsWith('data:')) {
			continue;
		}
		dataIndexes.push(index);
		dataParts.push(lines[index].slice(5).replace(/^ /u, ''));
	}

	if (dataIndexes.length === 0) {
		return block;
	}

	const data = dataParts.join('\n');
	if (data.trim() === '[DONE]') {
		return block;
	}

	let rewrittenData;
	try {
		rewrittenData = JSON.stringify(rewriteResponseForCodex(JSON.parse(data), mapping));
	} catch {
		return block;
	}

	const firstDataIndex = dataIndexes[0];
	const removedIndexes = new Set(dataIndexes.slice(1));

	return lines
		.map((line, index) => (index === firstDataIndex ? `data: ${rewrittenData}` : line))
		.filter((_, index) => !removedIndexes.has(index))
		.join('\n');
}

export function createSseTransform(mapping) {
	let buffer = '';
	const decoder = new StringDecoder('utf8');

	return new Transform({
		transform(chunk, encoding, callback) {
			buffer += Buffer.isBuffer(chunk) ? decoder.write(chunk) : chunk;
			let match = /\r?\n\r?\n/u.exec(buffer);
			while (match) {
				const block = buffer.slice(0, match.index);
				this.push(transformSseBlock(block, mapping) + match[0]);
				buffer = buffer.slice(match.index + match[0].length);
				match = /\r?\n\r?\n/u.exec(buffer);
			}
			callback();
		},
		flush(callback) {
			buffer += decoder.end();
			if (buffer.length > 0) {
				this.push(transformSseBlock(buffer, mapping));
			}
			callback();
		}
	});
}

function copyHeaders(headers, { transformed = false } = {}) {
	const copied = {};
	for (const [name, value] of Object.entries(headers)) {
		const lowerName = name.toLowerCase();
		if (HOP_BY_HOP_HEADERS.has(lowerName)) {
			continue;
		}
		if (transformed && (lowerName === 'content-length' || lowerName === 'content-encoding')) {
			continue;
		}
		copied[name] = value;
	}

	return copied;
}

function sendError(response, statusCode, code, message) {
	if (response.headersSent) {
		response.destroy();

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
			throw new BridgeRequestError(
				413,
				'request_body_too_large',
				`Responses request exceeds the ${maxBodyBytes} byte bridge limit.`
			);
		}
		chunks.push(chunk);
	}

	return Buffer.concat(chunks);
}

function isResponsesRequest(request, targetUrl) {
	return request.method === 'POST' && targetUrl.pathname === '/v1/responses';
}

function proxyUpstreamResponse(upstreamResponse, response, mapping, transformResponses) {
	const contentType = String(upstreamResponse.headers['content-type'] ?? '').toLowerCase();
	const contentEncoding = String(upstreamResponse.headers['content-encoding'] ?? '').toLowerCase();
	const canTransform = transformResponses && (!contentEncoding || contentEncoding === 'identity');

	if (canTransform && contentType.includes('text/event-stream')) {
		response.writeHead(upstreamResponse.statusCode ?? 502, copyHeaders(upstreamResponse.headers, { transformed: true }));
		pipeline(upstreamResponse, createSseTransform(mapping), response, (error) => {
			if (error && !response.destroyed) {
				response.destroy(error);
			}
		});

		return;
	}

	if (canTransform && contentType.includes('application/json')) {
		const chunks = [];
		upstreamResponse.on('data', (chunk) => chunks.push(chunk));
		upstreamResponse.on('end', () => {
			const originalBody = Buffer.concat(chunks);
			let body = originalBody;
			try {
				body = Buffer.from(JSON.stringify(rewriteResponseForCodex(JSON.parse(originalBody.toString('utf8')), mapping)));
			} catch {
				// Preserve malformed or non-JSON upstream payloads verbatim.
			}
			const headers = copyHeaders(upstreamResponse.headers, { transformed: true });
			headers['content-length'] = body.length;
			response.writeHead(upstreamResponse.statusCode ?? 502, headers);
			response.end(body);
		});
		upstreamResponse.on('error', (error) => {
			if (!response.destroyed) {
				response.destroy(error);
			}
		});

		return;
	}

	response.writeHead(upstreamResponse.statusCode ?? 502, copyHeaders(upstreamResponse.headers));
	pipeline(upstreamResponse, response, (error) => {
		if (error && !response.destroyed) {
			response.destroy(error);
		}
	});
}

function proxyRequest({ request, response, targetUrl, headers, body, mapping, transformResponses, onUpstreamAbort }) {
	const transport = targetUrl.protocol === 'https:' ? https : http;
	const startedAt = Date.now();
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
			response.on('finish', () => {
				console.log(
					`[${SERVICE_NAME}] ${request.method} ${targetUrl.pathname} -> ${upstreamResponse.statusCode} (${Date.now() - startedAt}ms)`
				);
			});
			proxyUpstreamResponse(upstreamResponse, response, mapping, transformResponses);
		}
	);

	const abortUpstream = () => {
		if (!upstreamRequest.destroyed) {
			upstreamRequest.destroy(new Error('downstream client disconnected'));
			onUpstreamAbort?.();
		}
	};
	request.once('aborted', abortUpstream);
	request.socket.once('close', () => {
		if (!response.writableEnded) {
			abortUpstream();
		}
	});
	response.once('close', () => {
		if (!response.writableEnded) {
			abortUpstream();
		}
	});

	upstreamRequest.on('error', (error) => {
		if (response.destroyed || response.writableEnded) {
			return;
		}
		sendError(response, 502, 'upstream_unavailable', `CLIProxyAPI is unavailable: ${error.message}`);
	});

	if (body) {
		upstreamRequest.end(body);

		return;
	}
	pipeline(request, upstreamRequest, (error) => {
		if (error && !upstreamRequest.destroyed) {
			upstreamRequest.destroy(error);
		}
	});
}

export function createBridgeServer(options = {}) {
	const upstreamUrl = new URL(options.upstreamUrl ?? DEFAULT_UPSTREAM);
	const buildId = options.buildId ?? 'development';
	const maxBodyBytes = options.maxBodyBytes ?? DEFAULT_MAX_BODY_BYTES;

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
		const transformResponses = isResponsesRequest(request, targetUrl);
		const headers = copyHeaders(request.headers, { transformed: transformResponses });
		headers.host = targetUrl.host;
		if (transformResponses) {
			headers['accept-encoding'] = 'identity';
		}

		let body;
		let mapping = { fullToOriginal: new Map(), namespaceToolToFlat: new Map(), uniqueBareToOriginal: new Map() };
		try {
			if (transformResponses) {
				const requestBody = await readBody(request, maxBodyBytes);
				let parsed;
				try {
					parsed = JSON.parse(requestBody.toString('utf8'));
				} catch {
					throw new BridgeRequestError(400, 'invalid_json', 'Responses request body is not valid JSON.');
				}
				const flattened = flattenResponsesRequest(parsed);
				mapping = flattened.mapping;
				body = Buffer.from(JSON.stringify(flattened.body));
				headers['content-length'] = body.length;
			}
		} catch (error) {
			if (error instanceof BridgeRequestError) {
				sendError(response, error.statusCode, error.code, error.message);

				return;
			}
			sendError(response, 400, 'invalid_request', error.message);

			return;
		}

		proxyRequest({
			request,
			response,
			targetUrl,
			headers,
			body,
			mapping,
			transformResponses,
			onUpstreamAbort: options.onUpstreamAbort
		});
	});
}

function parsePositiveInteger(value, fallback) {
	const parsed = Number.parseInt(value ?? '', 10);

	return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function isMainModule() {
	if (!process.argv[1]) {
		return false;
	}

	return pathToFileURL(resolve(process.argv[1])).href === import.meta.url;
}

if (isMainModule()) {
	const host = process.env.CLIPROXY_BRIDGE_HOST ?? DEFAULT_HOST;
	const port = parsePositiveInteger(process.env.CLIPROXY_BRIDGE_PORT, DEFAULT_PORT);
	const upstreamUrl = process.env.CLIPROXY_UPSTREAM ?? DEFAULT_UPSTREAM;
	const buildId = process.env.CLIPROXY_BRIDGE_BUILD_ID ?? 'development';
	const maxBodyBytes = parsePositiveInteger(process.env.CLIPROXY_BRIDGE_MAX_BODY_BYTES, DEFAULT_MAX_BODY_BYTES);
	const server = createBridgeServer({ upstreamUrl, buildId, maxBodyBytes });

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
