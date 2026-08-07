import http from 'node:http';
import https from 'node:https';
import { pipeline } from 'node:stream';
import { fileURLToPath } from 'node:url';

const SERVICE_NAME = 'codex-model-shell-router';
const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_PORT = 8319;
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

function copyHeaders(headers) {
	const copied = {};
	for (const [name, value] of Object.entries(headers)) {
		if (!HOP_BY_HOP_HEADERS.has(name.toLowerCase()) && value !== undefined) {
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

	return { clientModel, upstreamModel, upstreamUrl: parsedUrl, apiKey };
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

function proxyRequest({ request, response, targetUrl, headers, body }) {
	const transport = targetUrl.protocol === 'https:' ? https : http;
	const startedAt = Date.now();

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
			response.writeHead(upstreamResponse.statusCode ?? 502, copyHeaders(upstreamResponse.headers));
			pipeline(upstreamResponse, response, (error) => {
				if (error && !response.destroyed) {
					console.error(`[${SERVICE_NAME}] pipeline error: ${error.message}`);
					response.destroy(error);
				}
			});
		}
	);

	upstreamRequest.setTimeout(600000);

	const abortUpstream = () => {
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

			body.model = route.upstreamModel;
			const upstreamBody = Buffer.from(JSON.stringify(body));
			const targetUrl = new URL(`${requestUrl.pathname}${requestUrl.search}`, route.upstreamUrl);
			const headers = copyHeaders(request.headers);
			headers.host = targetUrl.host;
			headers.authorization = `Bearer ${route.apiKey}`;
			headers['content-length'] = upstreamBody.length;
			delete headers['content-encoding'];

			proxyRequest({ request, response, targetUrl, headers, body: upstreamBody });
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
		apiKey: process.env[route.apiKeyEnv]
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

export { SERVICE_NAME };
