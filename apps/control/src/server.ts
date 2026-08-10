import { randomBytes } from 'node:crypto';

import fastifyStaticPlugin from '@fastify/static';
import Fastify, { type FastifyInstance } from 'fastify';

import { ControlRuntime } from './control-runtime';
import { EventHub } from './event-hub';
import { NssmClient } from './nssm-client';

import type { ControlConfig } from './config';
import type { DashboardLogSource } from '@ungate/shared';

const BACKEND_ROUTES = new Map<string, ReadonlySet<string>>([
	['/health', new Set(['GET'])],
	['/analytics', new Set(['GET'])],
	['/analytics/requests', new Set(['GET'])],
	['/analytics/tokens', new Set(['GET'])],
	['/analytics/cache', new Set(['GET'])],
	['/analytics/reset', new Set(['POST'])],
	['/settings', new Set(['GET', 'POST'])],
	['/models/validate', new Set(['POST'])],
	['/auth/claude/start', new Set(['POST'])],
	['/auth/claude/complete', new Set(['POST'])],
	['/auth/claude/status', new Set(['GET'])],
	['/auth/claude/logout', new Set(['POST'])],
	['/auth/minimax/status', new Set(['GET'])],
	['/auth/minimax/login', new Set(['POST'])],
	['/auth/minimax/base-url', new Set(['POST'])],
	['/auth/minimax/logout', new Set(['POST'])],
	['/auth/openai/start', new Set(['GET'])],
	['/auth/openai/status', new Set(['GET'])],
	['/auth/openai/logout', new Set(['POST'])],
	['/wake-ping', new Set(['GET', 'POST'])],
	['/wake-ping/ping', new Set(['POST'])]
]);

interface ServerDependencies {
	nssm?: NssmClient;
	fetcher?: typeof fetch;
}

function allowedHost(host: string | undefined, port: number): boolean {
	if (!host) return false;
	const normalized = host.toLowerCase();

	return (
		normalized === `127.0.0.1:${port}` ||
		normalized === `localhost:${port}` ||
		normalized === `[::1]:${port}` ||
		normalized === '127.0.0.1' ||
		normalized === 'localhost' ||
		normalized === '[::1]'
	);
}

function allowedOrigin(origin: string | undefined, port: number): boolean {
	if (!origin) return true;

	return origin === `http://127.0.0.1:${port}` || origin === `http://localhost:${port}` || origin === `http://[::1]:${port}`;
}

function requiresCsrf(method: string, pathname: string): boolean {
	if (pathname.startsWith('/api/backend/')) return true;

	return method !== 'GET' && method !== 'HEAD' && pathname.startsWith('/api/control/');
}

function normalizedLimit(value: unknown): number {
	const parsed = Number.parseInt(typeof value === 'string' ? value : '', 10);
	if (!Number.isInteger(parsed)) return 500;

	return Math.min(Math.max(parsed, 1), 500);
}

export async function buildServer(config: ControlConfig, dependencies: ServerDependencies = {}): Promise<FastifyInstance> {
	const app = Fastify({ logger: false });
	const events = new EventHub();
	const nssm = dependencies.nssm ?? new NssmClient(config.nssmPath);
	const runtime = new ControlRuntime(config, nssm, events, dependencies.fetcher);
	const csrfToken = randomBytes(32).toString('base64url');

	app.addHook('onRequest', async (request, reply) => {
		const pathname = new URL(request.raw.url ?? '/', 'http://localhost').pathname;

		if (!allowedHost(request.headers.host, config.port) || !allowedOrigin(request.headers.origin, config.port)) {
			return reply.code(403).send({ error: 'Local dashboard origin required' });
		}

		if (requiresCsrf(request.method, pathname) && request.headers['x-ungate-csrf'] !== csrfToken) {
			return reply.code(403).send({ error: 'Invalid CSRF token' });
		}
	});

	app.get('/health', async (_request, reply) => {
		return reply.send({ status: 'ok' });
	});

	app.get('/api/control/bootstrap', async (_request, reply) => {
		return reply.send({
			csrfToken,
			eventsUrl: '/api/events',
			features: { keyFix: false },
			status: await runtime.getStatus()
		});
	});

	app.get('/api/control/status', async (_request, reply) => {
		const status = await runtime.getStatus();

		return reply.send(status);
	});

	app.get('/api/control/logs', async (request, reply) => {
		const query = request.query as { source?: string; limit?: string };
		if (query.source !== 'api' && query.source !== 'tunnel') {
			return reply.code(400).send({ error: 'source must be api or tunnel' });
		}

		const logs = await runtime.getLogs(query.source as DashboardLogSource, normalizedLimit(query.limit));

		return reply.send(logs);
	});

	app.get('/api/control/operations/:id', async (request, reply) => {
		const { id } = request.params as { id: string };
		const operation = runtime.getOperation(id);

		if (!operation) return reply.code(404).send({ error: 'Operation not found' });

		return reply.send(operation);
	});

	app.post('/api/control/api/restart', async (_request, reply) => {
		return reply.code(202).send(runtime.beginOperation('api', 'restart'));
	});

	for (const action of ['start', 'stop', 'restart'] as const) {
		app.post(`/api/control/tunnel/${action}`, async (_request, reply) => {
			return reply.code(202).send(runtime.beginOperation('tunnel', action));
		});
	}

	app.get('/api/events', async (request, reply) => {
		reply.hijack();
		reply.raw.writeHead(200, {
			'Content-Type': 'text/event-stream',
			'Cache-Control': 'no-cache, no-transform',
			Connection: 'keep-alive',
			'X-Accel-Buffering': 'no'
		});
		const removeClient = events.add(reply.raw);
		request.raw.once('close', removeClient);
	});

	app.all('/api/backend/*', async (request, reply) => {
		const incomingUrl = new URL(request.raw.url ?? '/', 'http://localhost');
		const backendPath = incomingUrl.pathname.slice('/api/backend'.length);
		const allowedMethods = BACKEND_ROUTES.get(backendPath);

		if (!allowedMethods?.has(request.method)) {
			return reply.code(404).send({ error: 'Dashboard backend route is not allowed' });
		}

		const upstreamUrl = `${config.apiUrl}${backendPath}${incomingUrl.search}`;
		const headers: Record<string, string> = {};
		const contentType = request.headers['content-type'];
		if (contentType) headers['content-type'] = contentType;

		try {
			const response = await (dependencies.fetcher ?? fetch)(upstreamUrl, {
				method: request.method,
				headers,
				body: request.method === 'GET' || request.method === 'HEAD' ? undefined : JSON.stringify(request.body ?? {}),
				signal: AbortSignal.timeout(15_000)
			});
			const responseContentType = response.headers.get('content-type');
			if (responseContentType) reply.header('content-type', responseContentType);

			const responseBody = await response.arrayBuffer();

			return reply.code(response.status).send(Buffer.from(responseBody));
		} catch (error) {
			return reply.code(502).send({
				error: 'Ungate API is unavailable',
				detail: error instanceof Error ? error.message : String(error)
			});
		}
	});

	await app.register(fastifyStaticPlugin, {
		root: config.publicDir,
		prefix: '/',
		wildcard: false
	});

	app.setNotFoundHandler(async (request, reply) => {
		if (request.raw.url?.startsWith('/api/')) {
			return reply.code(404).send({ error: 'Not found' });
		}

		return reply.sendFile('index.html');
	});

	app.addHook('onReady', async () => {
		await runtime.start();
	});

	app.addHook('onClose', () => {
		runtime.stop();
		events.close();
	});

	return app;
}
