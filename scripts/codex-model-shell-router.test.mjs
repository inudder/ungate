import assert from 'node:assert/strict';
import http from 'node:http';
import test from 'node:test';

import { createShellRouterServer } from './codex-model-shell-router.mjs';

function listen(server) {
	return new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(0, '127.0.0.1', () => resolve(server.address().port));
	});
}

function close(server) {
	return new Promise((resolve, reject) =>
		server.close((error) => {
			if (error) {
				reject(error instanceof Error ? error : new Error('Server close failed.'));

				return;
			}
			resolve();
		})
	);
}

test('lists shells and rewrites a Responses request to its upstream model', async () => {
	let upstreamRequest;
	const upstream = http.createServer(async (request, response) => {
		const chunks = [];
		for await (const chunk of request) {
			chunks.push(chunk);
		}
		upstreamRequest = {
			authorization: request.headers.authorization,
			body: JSON.parse(Buffer.concat(chunks).toString('utf8'))
		};
		const payload = JSON.stringify({ object: 'response', output: [] });
		response.writeHead(200, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(payload) });
		response.end(payload);
	});
	const upstreamPort = await listen(upstream);
	const router = createShellRouterServer({
		buildId: 'test-build',
		routes: [
			{
				clientModel: 'gpt-5.6-sol',
				upstreamModel: 'ungate-opus-4-8',
				upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
				apiKey: 'target-key'
			}
		]
	});
	const routerPort = await listen(router);

	try {
		const modelsResponse = await fetch(`http://127.0.0.1:${routerPort}/v1/models`);
		assert.equal(modelsResponse.status, 200);
		const models = await modelsResponse.json();
		assert.deepEqual(
			models.data.map((model) => model.id),
			['gpt-5.6-sol']
		);

		const response = await fetch(`http://127.0.0.1:${routerPort}/v1/responses`, {
			method: 'POST',
			headers: { authorization: 'Bearer client-key', 'content-type': 'application/json' },
			body: JSON.stringify({ model: 'gpt-5.6-sol', input: 'ping', stream: false })
		});
		assert.equal(response.status, 200);
		assert.deepEqual(await response.json(), { object: 'response', output: [] });
		assert.equal(upstreamRequest.authorization, 'Bearer target-key');
		assert.equal(upstreamRequest.body.model, 'ungate-opus-4-8');
	} finally {
		await close(router);
		await close(upstream);
	}
});

test('preserves streaming upstream responses and rejects unmapped models', async () => {
	const upstream = http.createServer((_request, response) => {
		response.writeHead(200, { 'content-type': 'text/event-stream' });
		response.end('event: response.completed\ndata: {"type":"response.completed"}\n\n');
	});
	const upstreamPort = await listen(upstream);
	const router = createShellRouterServer({
		routes: [
			{
				clientModel: 'gpt-5.6-terra',
				upstreamModel: 'grok-4.5',
				upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
				apiKey: 'target-key'
			}
		]
	});
	const routerPort = await listen(router);

	try {
		const streamingResponse = await fetch(`http://127.0.0.1:${routerPort}/v1/responses`, {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({ model: 'gpt-5.6-terra', stream: true })
		});
		assert.equal(streamingResponse.status, 200);
		assert.match(await streamingResponse.text(), /response.completed/);

		const unknownResponse = await fetch(`http://127.0.0.1:${routerPort}/v1/responses`, {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({ model: 'not-a-shell' })
		});
		assert.equal(unknownResponse.status, 400);
		const unknownPayload = await unknownResponse.json();
		assert.equal(unknownPayload.error.code, 'unknown_model_shell');
	} finally {
		await close(router);
		await close(upstream);
	}
});
