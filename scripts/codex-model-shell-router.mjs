import http from 'node:http';
import https from 'node:https';
import { pipeline } from 'node:stream';
import { fileURLToPath } from 'node:url';

import { flattenMimoResponsesRequest, restoreMimoResponsesValue } from './mimo-responses-namespace.mjs';
import { createMimoResponsesStreamAdapter } from './mimo-responses-stream-adapter.mjs';

const SERVICE_NAME = 'codex-model-shell-router';
const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_PORT = 8319;
const DEFAULT_MAX_BODY_BYTES = 128 * 1024 * 1024;
const DEFAULT_SSE_KEEPALIVE_MS = 5000;
const MIMO_RESPONSES_ADAPTER = 'mimo-textual-tools';
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

function normalizeRoute(route) {
	if (!route || typeof route !== 'object') {
		throw new Error('A shell router route must be an object.');
	}

	const clientModel = String(route.clientModel ?? '').trim();
	const upstreamModel = String(route.upstreamModel ?? '').trim();
	const upstreamBaseUrl = String(route.upstreamBaseUrl ?? '').trim();
	const apiKey = String(route.apiKey ?? '').trim();
	const responsesAdapter = String(route.responsesAdapter ?? '').trim() || null;
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
	if (responsesAdapter && responsesAdapter !== MIMO_RESPONSES_ADAPTER) {
		throw new Error(`Unsupported Responses stream adapter '${responsesAdapter}' for model shell '${clientModel}'.`);
	}

	return { clientModel, upstreamModel, upstreamUrl: parsedUrl, apiKey, responsesAdapter };
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
	sseKeepAliveMs,
	namespaceMapping
}) {
	const transport = targetUrl.protocol === 'https:' ? https : http;
	const startedAt = Date.now();
	const keepAlive = responsesAdapter === MIMO_RESPONSES_ADAPTER ? startSseKeepAlive(response, sseKeepAliveMs) : null;
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
			response.on('finish', () => {
				console.log(
					`[${SERVICE_NAME}] ${request.method} ${targetUrl.pathname} -> ${upstreamResponse.statusCode} (${Date.now() - startedAt}ms)`
				);
			});
			const contentType = String(upstreamResponse.headers['content-type'] ?? '').toLowerCase();
			const adapterEnabled =
				responsesAdapter === MIMO_RESPONSES_ADAPTER &&
				(upstreamResponse.statusCode ?? 500) >= 200 &&
				(upstreamResponse.statusCode ?? 500) < 300 &&
				contentType.includes('text/event-stream');
			const rewriteJson = namespaceMapping && contentType.includes('application/json');
			if (rewriteJson) {
				const chunks = [];
				upstreamResponse.on('data', (chunk) => chunks.push(chunk));
				upstreamResponse.on('end', () => {
					const originalBody = Buffer.concat(chunks);
					let bodyBuffer = originalBody;
					try {
						bodyBuffer = Buffer.from(
							JSON.stringify(restoreMimoResponsesValue(JSON.parse(originalBody.toString('utf8')), namespaceMapping))
						);
					} catch {
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
			const streamAdapter = adapterEnabled
				? createMimoResponsesStreamAdapter({
						model,
						namespaceMapping,
						logger: (message) => console.error(`[${SERVICE_NAME}] ${message}`)
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
					console.error(`[${SERVICE_NAME}] pipeline error: ${error.message}`);
					response.destroy(error);
				}
			};
			try {
				if (!response.destroyed && !response.writableEnded) {
					const streamPipeline = streamAdapter
						? pipeline(upstreamResponse, streamAdapter, response, onPipelineError)
						: pipeline(upstreamResponse, response, onPipelineError);
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
	request.socket.once('close', () => {
		if (!response.writableEnded && !response.destroyed) {
			abortUpstream();
		}
	});

	upstreamRequest.on('error', (error) => {
		keepAlive?.stop();
		if (downstreamDisconnected || response.destroyed || response.writableEnded) return;
		console.error(`[${SERVICE_NAME}] upstream request error: ${error.message}`);
		if (!response.destroyed && !response.writableEnded) {
			sendError(response, 502, 'upstream_unavailable', `Mapped upstream is unavailable: ${error.message}`);
		}
	});

	upstreamRequest.end(body);
}

export function createShellRouterServer(options = {}) {
	const routes = normalizeRoutes(options.routes);
	const buildId = options.buildId ?? 'development';
	const maxBodyBytes = options.maxBodyBytes ?? DEFAULT_MAX_BODY_BYTES;
	const sseKeepAliveMs = parsePositiveInteger(options.sseKeepAliveMs, DEFAULT_SSE_KEEPALIVE_MS);

	return http.createServer(async (request, response) => {
		const requestUrl = new URL(request.url ?? '/', 'http://shell-router.local');
		if (request.method === 'GET' && requestUrl.pathname === '/_shell-router/health') {
			const body = JSON.stringify({
				status: 'ok',
				service: SERVICE_NAME,
				pid: process.pid,
				build_id: buildId,
				route_models: [...routes.values()].map((route) => route.clientModel)
			});
			response.writeHead(200, {
				'content-type': 'application/json; charset=utf-8',
				'content-length': Buffer.byteLength(body)
			});
			response.end(body);

			return;
		}

		if (request.method === 'GET' && requestUrl.pathname === '/v1/models') {
			const body = JSON.stringify({
				object: 'list',
				data: [...routes.values()].map((route) => ({
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

		try {
			const requestBody = await readBody(request, maxBodyBytes);
			let body;
			try {
				body = JSON.parse(requestBody.toString('utf8'));
			} catch {
				throw new ShellRouterRequestError(400, 'invalid_json', 'Request body is not valid JSON.');
			}
			const requestedModel = typeof body.model === 'string' ? body.model.trim() : '';
			const route = routes.get(requestedModel.toLowerCase());
			if (!route) {
				const requestedModelLabel = requestedModel === '' ? '(empty)' : requestedModel;
				throw new ShellRouterRequestError(400, 'unknown_model_shell', `Unknown Codex model shell '${requestedModelLabel}'.`);
			}

			let namespaceMapping = null;
			if (route.responsesAdapter === MIMO_RESPONSES_ADAPTER && requestUrl.pathname === '/v1/responses') {
				const flattened = flattenMimoResponsesRequest(body);
				body = flattened.body;
				namespaceMapping = flattened.mapping;
			}

			body.model = route.upstreamModel;
			const upstreamBody = Buffer.from(JSON.stringify(body));
			const targetUrl = new URL(`${requestUrl.pathname}${requestUrl.search}`, route.upstreamUrl);
			const headers = copyHeaders(request.headers);
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

			proxyRequest({
				request,
				response,
				targetUrl,
				headers,
				body: upstreamBody,
				model: route.upstreamModel,
				responsesAdapter:
					route.responsesAdapter && requestUrl.pathname === '/v1/responses' && body.stream === true
						? route.responsesAdapter
						: null,
				sseKeepAliveMs,
				namespaceMapping
			});
		} catch (error) {
			if (error instanceof ShellRouterRequestError) {
				sendError(response, error.statusCode, error.code, error.message);

				return;
			}
			sendError(response, 400, 'invalid_request', error instanceof Error ? error.message : String(error));
		}
	});
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
		responsesAdapter: route.responsesAdapter
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
	process.on('uncaughtException', (err) => {
		console.error(`[${SERVICE_NAME}] uncaughtException:`, err);
	});
	process.on('unhandledRejection', (reason) => {
		console.error(`[${SERVICE_NAME}] unhandledRejection:`, reason);
	});
}

export { MIMO_RESPONSES_ADAPTER, SERVICE_NAME };
