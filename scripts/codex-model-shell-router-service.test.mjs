import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, writeFile } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { PassThrough } from 'node:stream';
import test from 'node:test';

import { decryptEnvelope, startShellRouterService } from './codex-model-shell-router-service.mjs';
import { runRouter, safeFailureDetails } from './codex-shell-router-supervisor.mjs';

const listen = (server) =>
	new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(0, '127.0.0.1', () => resolve(server.address().port));
	});
const close = (server) =>
	new Promise((resolve) => {
		server.closeAllConnections();
		server.close(resolve);
	});
const health = async (port) => {
	const response = await fetch(`http://127.0.0.1:${port}/_shell-router/health`);

	return response.json();
};
const waitFor = async (fn) => {
	for (let i = 0; i < 100; i++) {
		const value = await fn();
		if (value) return value;
		await new Promise((resolve) => setTimeout(resolve, 50));
	}
	throw new Error('fixture operation timed out');
};
const waitForHealth = (port, field, expected) =>
	waitFor(async () => {
		const current = await health(port);

		return current[field] === expected;
	});

test('supervisor merges both streams and reports a failed child exit', async () => {
	const output = new PassThrough();
	let captured = '';
	output.setEncoding('utf8');
	output.on('data', (chunk) => {
		captured += chunk;
	});
	const code = await runRouter({
		executable: process.execPath,
		args: ['-e', "process.stdout.write('fixture-stdout\\n'); process.stderr.write('fixture-stderr\\n'); process.exitCode = 17;"],
		output
	});
	assert.equal(code, 1);
	assert.match(captured, /fixture-stdout/);
	assert.match(captured, /fixture-stderr/);
});

test('fatal diagnostics retain safe error details without exception messages or secrets', () => {
	const error = new TypeError('synthetic-private-key');
	error.code = 'EADDRINUSE';
	error.stack =
		'TypeError: synthetic-private-key\n' +
		'    at handler (file:///C:/runtime/codex-model-shell-router-service.mjs:123:45)\n' +
		'    at private (file:///C:/synthetic-private-key.mjs:1:2)';
	const details = safeFailureDetails(error);
	assert.deepEqual(details, {
		error_type: 'TypeError',
		error_code: 'EADDRINUSE',
		stack_frames: [{ file: 'codex-model-shell-router-service.mjs', line: 123, column: 45 }]
	});
	assert.doesNotMatch(JSON.stringify(details), /synthetic-private-key/);
	error.code = 'synthetic-private-key';
	assert.equal(safeFailureDetails(error).error_code, null);
	assert.equal(safeFailureDetails('synthetic-private-key').error_type, 'unknown');
});

test(
	'machine DPAPI helper decrypts an encrypted synthetic envelope without exposing it in arguments',
	{ skip: process.platform !== 'win32' },
	async () => {
		const fixture = { revision: randomUUID(), fixture: 'synthetic-key-only' };
		const command =
			'$v=[Console]::In.ReadLine();$b=[Convert]::FromBase64String($v);' +
			'$c=[Security.Cryptography.ProtectedData]::Protect($b,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine);' +
			'[Console]::Out.Write([Convert]::ToBase64String($c))';
		const child = spawnSync(
			'C:\\Program Files\\PowerShell\\7\\pwsh.exe',
			['-NoProfile', '-NonInteractive', '-Command', command],
			{
				input: `${Buffer.from(JSON.stringify(fixture)).toString('base64')}\n`,
				encoding: 'utf8',
				windowsHide: true
			}
		);
		assert.equal(child.status, 0);
		const encrypted = Buffer.from(child.stdout.trim(), 'base64');
		assert.equal(encrypted.includes(Buffer.from(fixture.fixture)), false);
		assert.deepEqual(await decryptEnvelope(encrypted), fixture);
		await assert.rejects(decryptEnvelope(Buffer.from('invalid')));
	}
);

test('corrupt committed configuration remains not ready', async () => {
	const root = await mkdtemp(path.join(os.tmpdir(), 'ungate-shell-service-'));
	let router;
	try {
		await mkdir(path.join(root, 'config'));
		await writeFile(path.join(root, 'config', 'active.bin'), 'corrupt synthetic envelope');
		router = await startShellRouterService({
			root,
			port: 0,
			decrypt: async () => {
				throw new Error('decrypt_failed');
			}
		});
		const result = await health(router.address().port);
		assert.equal(result.status, 'not_ready');
		assert.equal(result.config_error, 'decrypt_failed');
	} finally {
		if (router?.listening) await close(router);
		const resolvedRoot = await realpath(root);
		const relativeRoot = path.relative(await realpath(os.tmpdir()), resolvedRoot);
		if (
			!relativeRoot ||
			relativeRoot.startsWith('..') ||
			path.isAbsolute(relativeRoot) ||
			!path.basename(resolvedRoot).startsWith('ungate-shell-service-')
		)
			throw new Error('refusing unsafe fixture cleanup');
		await rm(resolvedRoot, { recursive: true, force: true });
	}
});

test('a foreign listener is left running when the service cannot bind', async () => {
	const root = await mkdtemp(path.join(os.tmpdir(), 'ungate-shell-service-'));
	const foreign = http.createServer((_request, response) => response.end('fixture'));
	try {
		const port = await listen(foreign);
		await assert.rejects(
			startShellRouterService({
				root,
				port,
				decrypt: async () => {
					throw Object.assign(new Error('missing'), { code: 'ENOENT' });
				}
			}),
			(error) => error.code === 'EADDRINUSE'
		);
		const foreignResponse = await fetch(`http://127.0.0.1:${port}/`);
		assert.equal(await foreignResponse.text(), 'fixture');
	} finally {
		await close(foreign);
		const resolvedRoot = await realpath(root);
		const relativeRoot = path.relative(await realpath(os.tmpdir()), resolvedRoot);
		if (
			!relativeRoot ||
			relativeRoot.startsWith('..') ||
			path.isAbsolute(relativeRoot) ||
			!path.basename(resolvedRoot).startsWith('ungate-shell-service-')
		)
			throw new Error('refusing unsafe fixture cleanup');
		await rm(resolvedRoot, { recursive: true, force: true });
	}
});

test(
	'service commits validated routes, preserves in-flight requests, and reloads the committed snapshot',
	{ timeout: 20000 },
	async () => {
		const root = await mkdtemp(path.join(os.tmpdir(), 'ungate-shell-service-'));
		let finishFirst;
		const upstream = http.createServer((request, response) => {
			const chunks = [];
			request.on('data', (chunk) => chunks.push(chunk));
			request.once('end', () => {
				const model = JSON.parse(Buffer.concat(chunks).toString('utf8')).model;
				response.writeHead(200, { 'content-type': 'text/plain', 'x-fixture-upstream-model': model });
				response.write('started');
				if (model === 'first-model') finishFirst = () => response.end('-finished');
				else response.end('-finished');
			});
		});
		const upstreamPort = await listen(upstream);
		const decrypt = async (file) => {
			const content = await readFile(file, 'utf8');

			return JSON.parse(content);
		};
		let router;
		const submit = async (action, extra = {}) => {
			const revision = randomUUID();
			const payload = { action, revision, expiresAt: new Date(Date.now() + 30000).toISOString(), ...extra };
			const temporary = path.join(root, 'config', `pending-${revision}.tmp`);
			await writeFile(temporary, JSON.stringify(payload));
			await rename(temporary, path.join(root, 'config', `pending-${revision}.bin`));

			return revision;
		};
		const route = (name) => ({
			clientModel: 'shell',
			upstreamModel: name,
			upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
			apiKey: 'synthetic-fixture-key'
		});
		const configuration = (name) => ({ routes: [route(name)], toolsCachePath: 'C:\\fixture\\tools-schema-cache.json' });
		try {
			router = await startShellRouterService({ root, port: 0, decrypt });
			let port = router.address().port;
			let currentHealth = await health(port);
			assert.equal(currentHealth.status, 'not_ready');
			const first = await submit('config', configuration('first-model'));
			await waitForHealth(port, 'config_revision', first);
			const stream = await fetch(`http://127.0.0.1:${port}/v1/responses`, {
				method: 'POST',
				headers: { 'content-type': 'application/json' },
				body: JSON.stringify({ model: 'shell' })
			});
			await waitForHealth(port, 'active_requests', 1);
			const second = await submit('config', configuration('second-model'));
			await waitForHealth(port, 'config_revision', second);
			const nextStream = await fetch(`http://127.0.0.1:${port}/v1/responses`, {
				method: 'POST',
				headers: { 'content-type': 'application/json' },
				body: JSON.stringify({ model: 'shell' })
			});
			assert.equal(stream.headers.get('x-fixture-upstream-model'), 'first-model');
			assert.equal(nextStream.headers.get('x-fixture-upstream-model'), 'second-model');
			currentHealth = await health(port);
			assert.equal(currentHealth.active_requests, 1);
			finishFirst();
			assert.equal(await stream.text(), 'started-finished');
			assert.equal(await nextStream.text(), 'started-finished');
			const backups = await readdir(path.join(root, 'config', 'backups'));
			assert.equal(backups.length, 1);
			const bad = await submit('config', {
				routes: [route(''), route('duplicate')],
				toolsCachePath: 'C:\\fixture\\tools-schema-cache.json'
			});
			await waitForHealth(port, 'error_revision', bad);
			currentHealth = await health(port);
			assert.equal(currentHealth.config_revision, second);
			const drain = await submit('drain', { leaseMs: 5000 });
			await waitForHealth(port, 'command_revision', drain);
			const rejected = await fetch(`http://127.0.0.1:${port}/v1/responses`, { method: 'POST' });
			assert.equal(rejected.status, 503);
			const resume = await submit('resume');
			await waitForHealth(port, 'command_revision', resume);
			currentHealth = await health(port);
			assert.equal(currentHealth.draining, false);
			await close(router);
			router = await startShellRouterService({ root, port: 0, decrypt });
			port = router.address().port;
			currentHealth = await health(port);
			assert.equal(currentHealth.config_revision, second);
			assert.equal(currentHealth.status, 'ok');
			assert.equal(JSON.stringify(currentHealth).includes('synthetic-fixture-key'), false);
		} finally {
			if (router?.listening) await close(router);
			await close(upstream);
			const resolvedRoot = await realpath(root);
			const resolvedTemp = await realpath(os.tmpdir());
			const relativeRoot = path.relative(resolvedTemp, resolvedRoot);
			if (
				!relativeRoot ||
				relativeRoot.startsWith('..') ||
				path.isAbsolute(relativeRoot) ||
				!path.basename(resolvedRoot).startsWith('ungate-shell-service-')
			)
				throw new Error('refusing unsafe fixture cleanup');
			await rm(resolvedRoot, { recursive: true, force: true });
		}
	}
);
