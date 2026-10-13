import { createServer, type Server, type RequestListener } from 'node:http';
import { connect, type Socket } from 'node:net';

import { afterEach, describe, expect, it, vi } from 'vitest';

import { OAuth } from 'src/auth/oauth';
import { config } from 'src/config';
import { ProviderSettings } from 'src/database/provider-settings';
import { closeClaudeTransport, fetchClaude } from 'src/proxy/claude-transport';

const tokenUrl = config.claude.oauth.tokenUrl;
const previousProxy = process.env.UNGATE_CLAUDE_PROXY_URL;
let server: Server | undefined;
let upstream: Server | undefined;
const sockets = new Set<Socket>();

function track(socket: Socket): void {
	sockets.add(socket);
	socket.on('close', () => sockets.delete(socket));
	socket.on('error', () => {});
}

async function listen(instance: Server): Promise<number> {
	await new Promise<void>((resolve) => instance.listen({ host: '127.0.0.1', port: 0, exclusive: true }, resolve));
	const address = instance.address();
	if (!address || typeof address === 'string') throw new Error('Missing isolated listener');

	return address.port;
}

async function proxy(status: number, body: unknown, handler?: RequestListener, connectStatus = 200): Promise<void> {
	upstream = createServer(
		handler ??
			((_request, response) => {
				response.writeHead(status, { 'Content-Type': 'application/json', 'Retry-After': '60' });
				response.end(JSON.stringify(body));
			})
	);
	upstream.on('connection', track);
	const upstreamPort = await listen(upstream);
	server = createServer();
	server.on('connection', track);
	server.on('connect', (_request, socket, head) => {
		if (connectStatus === 0) return;
		if (connectStatus !== 200) {
			socket.end(`HTTP/1.1 ${connectStatus} Rejected\r\nContent-Length: 0\r\n\r\n`);

			return;
		}
		// Map the fictitious Claude host to the isolated origin, without external DNS.
		const target = connect(upstreamPort, '127.0.0.1', () => {
			socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
			if (head.length) target.write(head);
			socket.pipe(target);
			target.pipe(socket);
		});
		track(target);
		socket.on('close', () => target.destroy());
		target.on('close', () => socket.destroy());
	});
	process.env.UNGATE_CLAUDE_PROXY_URL = `http://127.0.0.1:${await listen(server)}`;
	(config.claude.oauth as { tokenUrl: string }).tokenUrl = 'http://claude-oauth.invalid/token';
}

function seed(): void {
	ProviderSettings.upsertOAuth('claude', { accessToken: 'old', refreshToken: 'old-refresh', expiresAt: Date.now() - 1000 });
}

describe('isolated Claude proxy', () => {
	afterEach(async () => {
		vi.restoreAllMocks();
		for (const socket of sockets) socket.destroy();
		await closeClaudeTransport();
		for (const instance of [server, upstream]) {
			if (instance?.listening) await new Promise<void>((resolve) => instance.close(() => resolve()));
		}
		server = undefined;
		upstream = undefined;
		(config.claude.oauth as { tokenUrl: string }).tokenUrl = tokenUrl;
		if (previousProxy === undefined) delete process.env.UNGATE_CLAUDE_PROXY_URL;
		else process.env.UNGATE_CLAUDE_PROXY_URL = previousProxy;
	});

	it('exchanges tokens through CONNECT and returns no credentials in status', async () => {
		await proxy(200, { access_token: 'proxy-access', refresh_token: 'proxy-refresh', expires_in: 3600 });
		seed();
		const status = await OAuth.refreshAuthStatus();
		expect(status).toMatchObject({ authenticated: true, state: 'ready' });
		expect(JSON.stringify(status)).not.toContain('proxy-access');
		expect(JSON.stringify(status)).not.toContain('proxy-refresh');
		expect(ProviderSettings.get('claude')?.refreshToken).toBe('proxy-refresh');
	});

	it.each([403, 429, 503])('preserves credentials when Claude returns HTTP %s', async (status) => {
		await proxy(status, { error: { type: 'forbidden', message: 'Request not allowed' } });
		seed();
		const result1 = await OAuth.refreshAuthStatus();
		expect(result1.state).toBe('retry_wait');
		expect(ProviderSettings.get('claude')?.refreshToken).toBe('old-refresh');
	});

	it.each([403, 407, 503])('safely retries a rejected CONNECT with status %s', async (status) => {
		await proxy(200, {}, undefined, status);
		seed();
		const result2 = await OAuth.refreshAuthStatus();
		expect(result2).toMatchObject({ state: 'retry_wait', errorCode: 'proxy_unavailable' });
		expect(ProviderSettings.get('claude')?.refreshToken).toBe('old-refresh');
	});

	it('retries a CONNECT timeout before the OAuth request is sent', async () => {
		await proxy(200, {}, undefined, 0);
		const originalTimeout = AbortSignal.timeout.bind(AbortSignal);
		vi.spyOn(AbortSignal, 'timeout').mockImplementation(() => originalTimeout(100));
		seed();
		const status = await OAuth.refreshAuthStatus();
		expect(status).toMatchObject({ state: 'retry_wait', errorCode: 'proxy_unavailable' });
		expect(ProviderSettings.get('claude')?.refreshToken).toBe('old-refresh');
	});

	it('keeps credentials after a refused proxy connection without direct access', async () => {
		await proxy(200, {});
		await new Promise<void>((resolve) => server!.close(() => resolve()));
		server = undefined;
		seed();
		const result3 = await OAuth.refreshAuthStatus();
		expect(result3).toMatchObject({ state: 'retry_wait', errorCode: 'proxy_unavailable' });
		expect(ProviderSettings.get('claude')?.refreshToken).toBe('old-refresh');
	});

	it('stops replaying an exchange after a timeout with the request already sent', async () => {
		let requests = 0;
		await proxy(200, {}, (request) => {
			request.resume();
			requests += 1;
		});
		const originalTimeout = AbortSignal.timeout.bind(AbortSignal);
		vi.spyOn(AbortSignal, 'timeout').mockImplementation(() => originalTimeout(100));
		seed();
		const result4 = await OAuth.refreshAuthStatus();
		expect(result4).toMatchObject({ state: 'reauth_required', errorCode: 'refresh_uncertain' });
		await OAuth.refreshAuthStatus();
		expect(requests).toBe(1);
		expect(ProviderSettings.get('claude')?.refreshToken).toBe('old-refresh');
	});

	it('preserves credentials and requests login after invalid_grant', async () => {
		await proxy(400, { error: 'invalid_grant' });
		seed();
		const result5 = await OAuth.refreshAuthStatus();
		expect(result5).toMatchObject({ state: 'reauth_required', errorCode: 'refresh_invalid' });
		expect(ProviderSettings.get('claude')?.refreshToken).toBe('old-refresh');
	});

	it('delivers SSE chunks before the upstream stream finishes', async () => {
		let finish!: () => void;
		await proxy(200, {}, (_request, response) => {
			response.writeHead(200, { 'Content-Type': 'text/event-stream' });
			response.write('data: first\n\n');
			finish = () => response.end('data: last\n\n');
		});
		const response = await fetchClaude('http://claude-stream.invalid/events');
		const reader = response.body!.getReader();
		const result6 = await reader.read();
		expect(new TextDecoder().decode(result6.value)).toBe('data: first\n\n');
		finish();
		const result7 = await reader.read();
		expect(new TextDecoder().decode(result7.value)).toBe('data: last\n\n');
		const result8 = await reader.read();
		expect(result8.done).toBe(true);
	});
});
