import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { NssmClient } from '../src/nssm-client';
import { buildServer } from '../src/server';

import type { ControlConfig } from '../src/config';
import type { DashboardServiceAction, DashboardServicePhase } from '@ungate/shared';
import type { FastifyInstance } from 'fastify';

function parseJson<T>(body: string): T {
	return JSON.parse(body) as unknown as T;
}

class FakeNssmClient extends NssmClient {
	readonly actions: { serviceName: string; action: DashboardServiceAction }[] = [];
	readonly statuses = new Map<string, DashboardServicePhase>([
		['ungate-api', 'running'],
		['frpc', 'running']
	]);

	constructor() {
		super('unused');
	}

	override get(): Promise<string> {
		return Promise.resolve('');
	}

	override status(serviceName: string): Promise<DashboardServicePhase> {
		return Promise.resolve(this.statuses.get(serviceName) ?? 'stopped');
	}

	override control(serviceName: string, action: DashboardServiceAction): Promise<void> {
		this.actions.push({ serviceName, action });
		this.statuses.set(serviceName, action === 'stop' ? 'stopped' : 'running');

		return Promise.resolve();
	}
}

describe('dashboard control server', () => {
	let app: FastifyInstance;
	let publicDir: string;
	let nssm: FakeNssmClient;
	let fetcher: ReturnType<typeof vi.fn<typeof fetch>>;
	let config: ControlConfig;

	beforeEach(async () => {
		publicDir = await mkdtemp(path.join(tmpdir(), 'ungate-control-'));
		await writeFile(path.join(publicDir, 'index.html'), '<html>dashboard</html>', 'utf8');
		nssm = new FakeNssmClient();
		fetcher = vi.fn<typeof fetch>((input) => {
			const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;

			if (url.endsWith('/settings')) {
				return Promise.resolve(Response.json({ port: 47821, apiKey: null, quiet: false, extraInstruction: null, models: [] }));
			}

			return Promise.resolve(Response.json({ status: 'ok' }));
		});
		config = {
			host: '127.0.0.1',
			port: 47820,
			apiPort: 47821,
			apiUrl: 'http://127.0.0.1:47821',
			apiServiceName: 'ungate-api',
			tunnelServiceName: 'frpc',
			tunnelHealthUrl: 'https://ungate.ahref.cyou/health',
			nssmPath: 'unused',
			publicDir,
			statusPollIntervalMs: 60_000,
			logPollIntervalMs: 60_000,
			operationTimeoutMs: 1000
		};
		app = await buildServer(config, { nssm, fetcher });
		await app.ready();
	});

	afterEach(async () => {
		await app.close();
		await rm(publicDir, { recursive: true, force: true });
	});

	it('serves the SPA and loopback health endpoint', async () => {
		const health = await app.inject({ method: 'GET', url: '/health', headers: { host: '127.0.0.1:47820' } });
		const spa = await app.inject({ method: 'GET', url: '/settings/deep-link', headers: { host: 'localhost:47820' } });

		expect(health.statusCode).toBe(200);
		expect(health.json()).toEqual({ status: 'ok' });
		expect(spa.statusCode).toBe(200);
		expect(spa.body).toContain('dashboard');
	});

	it('requires the bootstrap CSRF token for proxied API access', async () => {
		const denied = await app.inject({
			method: 'GET',
			url: '/api/backend/settings',
			headers: { host: '127.0.0.1:47820' }
		});
		expect(denied.statusCode).toBe(403);

		const bootstrap = await app.inject({
			method: 'GET',
			url: '/api/control/bootstrap',
			headers: { host: '127.0.0.1:47820' }
		});
		const token = parseJson<{ csrfToken: string }>(bootstrap.body).csrfToken;
		const allowed = await app.inject({
			method: 'GET',
			url: '/api/backend/settings',
			headers: { host: '127.0.0.1:47820', 'x-ungate-csrf': token }
		});
		const cacheAnalytics = await app.inject({
			method: 'GET',
			url: '/api/backend/analytics/cache?period=day',
			headers: { host: '127.0.0.1:47820', 'x-ungate-csrf': token }
		});

		expect(allowed.statusCode).toBe(200);
		expect(allowed.json()).toMatchObject({ port: 47821 });
		expect(cacheAnalytics.statusCode).toBe(200);
		expect(fetcher).toHaveBeenCalledWith(
			'http://127.0.0.1:47821/analytics/cache?period=day',
			expect.objectContaining({ method: 'GET' })
		);
	});

	it('rejects foreign origins and non-allowlisted backend routes', async () => {
		const foreign = await app.inject({
			method: 'GET',
			url: '/health',
			headers: { host: '127.0.0.1:47820', origin: 'https://example.com' }
		});
		expect(foreign.statusCode).toBe(403);

		const bootstrap = await app.inject({
			method: 'GET',
			url: '/api/control/bootstrap',
			headers: { host: '127.0.0.1:47820' }
		});
		const token = parseJson<{ csrfToken: string }>(bootstrap.body).csrfToken;
		const denied = await app.inject({
			method: 'GET',
			url: '/api/backend/v1/models',
			headers: { host: '127.0.0.1:47820', 'x-ungate-csrf': token }
		});

		expect(denied.statusCode).toBe(404);
	});

	it('keeps a running FRP service running when its external HTTP check is unsuccessful', async () => {
		fetcher.mockImplementation((input) => {
			const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;

			if (url === config.tunnelHealthUrl) {
				return Promise.resolve(new Response('not found', { status: 404 }));
			}

			return Promise.resolve(Response.json({ status: 'ok' }));
		});

		const statusResponse = await app.inject({
			method: 'GET',
			url: '/api/control/status',
			headers: { host: '127.0.0.1:47820' }
		});
		expect(statusResponse.json()).toMatchObject({
			tunnel: {
				phase: 'running',
				healthy: false,
				error: null
			}
		});

		const bootstrap = await app.inject({
			method: 'GET',
			url: '/api/control/bootstrap',
			headers: { host: '127.0.0.1:47820' }
		});
		const token = parseJson<{ csrfToken: string }>(bootstrap.body).csrfToken;
		const restart = await app.inject({
			method: 'POST',
			url: '/api/control/tunnel/restart',
			headers: { host: '127.0.0.1:47820', 'x-ungate-csrf': token }
		});
		const id = parseJson<{ id: string }>(restart.body).id;

		let state = 'queued';
		for (let attempt = 0; attempt < 20 && state !== 'succeeded'; attempt++) {
			await new Promise((resolve) => setTimeout(resolve, 10));
			const operation = await app.inject({
				method: 'GET',
				url: `/api/control/operations/${id}`,
				headers: { host: '127.0.0.1:47820' }
			});
			state = parseJson<{ state: string }>(operation.body).state;
		}

		expect(state).toBe('succeeded');
		expect(nssm.actions).toContainEqual({ serviceName: 'frpc', action: 'restart' });
	});

	it('restarts only the configured API service and reports completion', async () => {
		const bootstrap = await app.inject({
			method: 'GET',
			url: '/api/control/bootstrap',
			headers: { host: '127.0.0.1:47820' }
		});
		const token = parseJson<{ csrfToken: string }>(bootstrap.body).csrfToken;
		const restart = await app.inject({
			method: 'POST',
			url: '/api/control/api/restart',
			headers: { host: '127.0.0.1:47820', 'x-ungate-csrf': token }
		});
		const id = parseJson<{ id: string }>(restart.body).id;

		expect(restart.statusCode).toBe(202);

		let state = 'queued';
		for (let attempt = 0; attempt < 20 && state !== 'succeeded'; attempt++) {
			await new Promise((resolve) => setTimeout(resolve, 10));
			const operation = await app.inject({
				method: 'GET',
				url: `/api/control/operations/${id}`,
				headers: { host: '127.0.0.1:47820' }
			});
			state = parseJson<{ state: string }>(operation.body).state;
		}

		expect(state).toBe('succeeded');
		expect(nssm.actions).toEqual([{ serviceName: 'ungate-api', action: 'restart' }]);
	});
});
