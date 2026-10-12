import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import { launcherPipeName, type LauncherTransport } from '../src/launcher-client';
import { buildServer } from '../src/server';

import type { ControlConfig } from '../src/config';

function readCsrfToken(body: string): string {
	const parsed: unknown = JSON.parse(body);
	if (!parsed || typeof parsed !== 'object' || !('csrfToken' in parsed)) return '';
	const token = (parsed as { csrfToken: unknown }).csrfToken;

	return typeof token === 'string' ? token : '';
}

const config = {
	host: '127.0.0.1',
	port: 47820,
	apiPort: 47821,
	apiUrl: 'http://127.0.0.1:47821',
	apiServiceName: 'ungate-api',
	tunnelServiceName: 'frpc',
	tunnelHealthUrl: 'https://example.invalid/health',
	nssmPath: 'unused',
	publicDir: '',
	statusPollIntervalMs: 60_000,
	logPollIntervalMs: 60_000,
	operationTimeoutMs: 1000,
	launcher: {
		profileId: 'default' as const,
		ownerSid: 'S-1-5-18',
		betaHome: 'C:\\Users\\kalvinclein\\.codex-ungate',
		pipeName: 'ungate-launcher-control-test',
		entryPoint: 'J:\\Dev\\ungate-local\\scripts\\start-codex-desktop-ungate.ps1',
		agentScript: 'J:\\Dev\\ungate-local\\scripts\\start-codex-launcher-control.ps1'
	}
} satisfies ControlConfig;

describe('launcher pipe name', () => {
	it('binds the pipe name to the owner and beta home', () => {
		expect(launcherPipeName('S-1-5-21-1291278068-251382271-1336519035-1001', 'C:\\Users\\kalvinclein\\.codex-ungate')).toBe(
			'ungate-launcher-control-39fb0825167dfe838294e2d86508e144'
		);
	});
});

describe('launcher routes', () => {
	it('requires CSRF and rejects an unknown field without calling the agent', async () => {
		const calls: string[] = [];
		const transport: LauncherTransport = {
			request(action) {
				calls.push(action);

				return Promise.resolve({ status: 200, body: { ok: true } });
			}
		};
		const publicDir = await mkdtemp(path.join(tmpdir(), 'ungate-launcher-'));
		await writeFile(path.join(publicDir, 'index.html'), 'ok');
		const app = await buildServer(
			{ ...config, publicDir },
			{ launcherTransport: transport, fetcher: () => Promise.resolve(Response.json({})) }
		);
		await app.ready();
		const denied = await app.inject({
			method: 'GET',
			url: '/api/control/launcher/state?profileId=default',
			headers: { host: '127.0.0.1:47820' }
		});
		expect(denied.statusCode).toBe(403);
		const bootstrap = await app.inject({ method: 'GET', url: '/api/control/bootstrap', headers: { host: '127.0.0.1:47820' } });
		const token = readCsrfToken(bootstrap.body);
		const malformed = await app.inject({
			method: 'POST',
			url: '/api/control/launcher/logging',
			headers: { host: '127.0.0.1:47820', 'x-ungate-csrf': token, 'content-type': 'application/json' },
			payload: { profileId: 'default', level: 'Standard', expectedRevision: 'abc', extra: true }
		});
		expect(malformed.statusCode).toBe(400);
		expect(calls).toEqual([]);
		await app.close();
		await rm(publicDir, { recursive: true, force: true });
	});

	it('forwards the caller request id and strips it from the agent payload', async () => {
		const calls: { action: string; requestId: string; payload: Record<string, unknown> }[] = [];
		const transport: LauncherTransport = {
			request(action, payload, requestId) {
				calls.push({ action, requestId, payload });

				return Promise.resolve({ status: 202, body: { operationId: 'op-1' } });
			}
		};
		const publicDir = await mkdtemp(path.join(tmpdir(), 'ungate-launcher-'));
		await writeFile(path.join(publicDir, 'index.html'), 'ok');
		const app = await buildServer(
			{ ...config, publicDir },
			{ launcherTransport: transport, fetcher: () => Promise.resolve(Response.json({})) }
		);
		await app.ready();
		const bootstrap = await app.inject({ method: 'GET', url: '/api/control/bootstrap', headers: { host: '127.0.0.1:47820' } });
		const token = readCsrfToken(bootstrap.body);
		const started = await app.inject({
			method: 'POST',
			url: '/api/control/launcher/diagnostics',
			headers: { host: '127.0.0.1:47820', 'x-ungate-csrf': token, 'content-type': 'application/json' },
			payload: { profileId: 'default', kind: 'tools', registryIds: ['grok-4.7'], requestId: 'request-12345678' }
		});
		expect(started.statusCode).toBe(202);
		expect(calls[0]).toMatchObject({ action: 'diagnostics.start', requestId: 'request-12345678' });
		expect(calls[0]?.payload.requestId).toBeUndefined();
		await app.close();
		await rm(publicDir, { recursive: true, force: true });
	});

	it('forwards model removal and template copy and rejects unknown fields', async () => {
		const calls: { action: string; payload: Record<string, unknown> }[] = [];
		const transport: LauncherTransport = {
			request(action, payload) {
				calls.push({ action, payload });

				return Promise.resolve({ status: 200, body: { ok: true } });
			}
		};
		const publicDir = await mkdtemp(path.join(tmpdir(), 'ungate-launcher-'));
		await writeFile(path.join(publicDir, 'index.html'), 'ok');
		const app = await buildServer(
			{ ...config, publicDir },
			{ launcherTransport: transport, fetcher: () => Promise.resolve(Response.json({})) }
		);
		await app.ready();
		const bootstrap = await app.inject({ method: 'GET', url: '/api/control/bootstrap', headers: { host: '127.0.0.1:47820' } });
		const headers = {
			host: '127.0.0.1:47820',
			'x-ungate-csrf': readCsrfToken(bootstrap.body),
			'content-type': 'application/json'
		};
		const body = { profileId: 'default', registryId: 'grok-4.7', expectedRevision: 'abc' };
		const removed = await app.inject({ method: 'POST', url: '/api/control/launcher/models/remove', headers, payload: body });
		const copied = await app.inject({ method: 'POST', url: '/api/control/launcher/models/add-template', headers, payload: body });
		const malformed = await app.inject({
			method: 'POST',
			url: '/api/control/launcher/models/remove',
			headers,
			payload: { ...body, force: true }
		});
		const malformedCopy = await app.inject({
			method: 'POST',
			url: '/api/control/launcher/models/add-template',
			headers,
			payload: { ...body, force: true }
		});
		const restored = await app.inject({ method: 'POST', url: '/api/control/launcher/models/restore', headers, payload: body });
		expect(removed.statusCode).toBe(200);
		expect(copied.statusCode).toBe(200);
		expect(malformed.statusCode).toBe(400);
		expect(malformedCopy.statusCode).toBe(400);
		expect(restored.statusCode).toBe(404);
		expect(calls.map((call) => call.action)).toEqual(['models.remove', 'models.addTemplate']);
		await app.close();
		await rm(publicDir, { recursive: true, force: true });
	});
});
