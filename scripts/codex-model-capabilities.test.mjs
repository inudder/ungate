import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { inflateSync } from 'node:zlib';

import {
	buildCapabilityChecks,
	capabilityExitCode,
	capabilityFingerprint,
	classifyCapabilityError,
	createVisionChallenge,
	probeCapability,
	reportStatus,
	runCapabilityDiagnostics
} from './codex-model-capabilities.mjs';
import { createShellRouterServer } from './codex-model-shell-router.mjs';

const DEFAULT_CAPABILITIES = {
	supportsImageInput: true,
	supportsImageDetailOriginal: false,
	supportedReasoningLevels: ['none', 'high'],
	defaultReasoningLevel: 'high',
	supportsReasoningSummaries: true,
	defaultReasoningSummary: 'none',
	supportsParallelToolCalls: false,
	supportVerbosity: false,
	defaultVerbosity: null
};

async function listen(server) {
	await new Promise((resolve) => server.listen({ host: '127.0.0.1', port: 0, exclusive: true }, resolve));

	return `http://127.0.0.1:${server.address().port}`;
}

async function close(server) {
	await new Promise((resolve) => {
		server.close(resolve);
		server.closeAllConnections();
	});
}

function event(response, type, fields = {}) {
	response.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...fields })}\n\n`);
}

function complete(response, text = 'OK', tools = []) {
	response.writeHead(200, { 'content-type': 'text/event-stream' });
	event(response, 'response.created', { response: { id: 'resp_test', status: 'in_progress', output: [] } });
	const output = [];
	if (text) {
		const item = {
			id: 'msg_test',
			type: 'message',
			role: 'assistant',
			status: 'completed',
			content: [{ type: 'output_text', text, annotations: [] }]
		};
		event(response, 'response.output_item.added', { output_index: 0, item: { ...item, status: 'in_progress', content: [] } });
		event(response, 'response.content_part.added', {
			item_id: item.id,
			output_index: 0,
			content_index: 0,
			part: { type: 'output_text', text: '', annotations: [] }
		});
		event(response, 'response.output_text.delta', { item_id: item.id, output_index: 0, content_index: 0, delta: text });
		event(response, 'response.output_text.done', { item_id: item.id, output_index: 0, content_index: 0, text });
		event(response, 'response.output_item.done', { output_index: 0, item });
		output.push(item);
	}
	for (const name of tools) {
		const item = {
			id: `item_${name}`,
			call_id: `call_${name}`,
			type: 'function_call',
			name,
			arguments: '{}',
			status: 'completed'
		};
		event(response, 'response.output_item.added', { output_index: output.length, item });
		event(response, 'response.output_item.done', { output_index: output.length, item });
		output.push(item);
	}
	event(response, 'response.completed', { response: { id: 'resp_test', status: 'completed', output } });
	response.end();
}

function readBands(imageUrl) {
	const png = Buffer.from(imageUrl.split(',')[1], 'base64');
	assert.deepEqual(png.subarray(0, 8), Buffer.from('89504e470d0a1a0a', 'hex'));
	let compressed;
	for (let offset = 8; offset < png.length; ) {
		const length = png.readUInt32BE(offset);
		if (png.toString('ascii', offset + 4, offset + 8) === 'IDAT') compressed = png.subarray(offset + 8, offset + 8 + length);
		offset += length + 12;
	}
	const row = inflateSync(compressed);
	const names = {
		'255,0,0': 'RED',
		'0,190,0': 'GREEN',
		'0,0,255': 'BLUE',
		'255,255,0': 'YELLOW',
		'255,0,255': 'MAGENTA',
		'0,255,255': 'CYAN'
	};

	return [0, 32, 64, 96].map((x) => names[[...row.subarray(1 + x * 3, 4 + x * 3)].join(',')]).join(',');
}

async function withDiagnostics(handler, action, capabilities = {}) {
	const directory = await mkdtemp(path.join(os.tmpdir(), 'ungate-cap-test-'));
	const upstream = http.createServer(async (request, response) => {
		let input = '';
		for await (const chunk of request) input += chunk;
		await handler(JSON.parse(input), response, request);
	});
	const upstreamBaseUrl = await listen(upstream);
	const config = {
		reportDirectory: directory,
		model: {
			registryId: 'mimo-v2.5-pro',
			model: 'mimo-v2.6-pro',
			displayName: 'Mimo',
			upstreamBaseUrl,
			responsesAdapter: 'mimo-textual-tools',
			apiKey: 'secret-test-key',
			capabilities: { ...DEFAULT_CAPABILITIES, ...capabilities }
		}
	};
	try {
		await action(config);
	} finally {
		await close(upstream);
		assert.ok(path.basename(directory).startsWith('ungate-cap-test-'));
		await rm(directory, { recursive: true });
	}
}

test('PNG payload actually contains the expected bands, independent of its answer metadata', () => {
	const image = createVisionChallenge(['CYAN', 'RED', 'GREEN', 'MAGENTA']);
	assert.equal(readBands(image.imageUrl), image.expected);
	assert.equal(image.expected, 'CYAN,RED,GREEN,MAGENTA');
	assert.throws(() => createVisionChallenge(['WHITE']));
});

test('image and original pass through the Mimo route; completion alone cannot prove vision', async () => {
	let images = 0;
	await withDiagnostics(
		(body, response) => {
			assert.equal(body.model, 'mimo-v2.6-pro');
			assert.equal(body.max_output_tokens, 512);
			const image = body.input[0].content?.find?.((part) => part.type === 'input_image');
			if (image) {
				images++;
				assert.ok(['auto', 'original'].includes(image.detail));
				complete(response, readBands(image.image_url));
			} else complete(response);
		},
		async (config) => {
			const result = await runCapabilityDiagnostics(config, { log: () => {} });
			assert.equal(result.exitCode, 0);
			assert.equal(images, 2);
			assert.equal(result.checks.filter((check) => check.name.startsWith('image:') && check.status === 'verified').length, 2);
			const report = await readFile(result.reportPath, 'utf8');
			assert.ok(!report.includes(config.model.apiKey));
			assert.ok(!report.includes('data:image'));
			assert.match(await reportStatus(config), /код 0/);
			config.model.capabilities.supportsImageDetailOriginal = false;
			assert.match(await reportStatus(config), /устарела/);
		},
		{ supportsImageDetailOriginal: true }
	);
	await withDiagnostics(
		(_body, response) => complete(response, 'OK'),
		async (config) => {
			const result = await runCapabilityDiagnostics(config, { log: () => {} });
			assert.equal(result.exitCode, 1);
			assert.equal(result.checks.find((check) => check.name === 'image:auto').status, 'wrong_answer');
		}
	);
});

test('vision verification accepts an explained final answer and rejects a contradictory final answer', async () => {
	for (const incorrect of [false, true]) {
		await withDiagnostics(
			(body, response) => {
				const image = body.input[0].content?.find?.((part) => part.type === 'input_image');
				if (!image) return complete(response);
				const colors = readBands(image.image_url).split(',');
				const final = incorrect ? [...colors].reverse() : colors;
				complete(
					response,
					`Based on the image provided:\n${colors.map((color, i) => `${i + 1}. **${color}**`).join('\n')}\n\n${final.join(', ')}.`
				);
			},
			async (config) => {
				const result = await runCapabilityDiagnostics(config, { log: () => {} });
				assert.equal(result.checks.find((check) => check.name === 'image:auto').status, incorrect ? 'wrong_answer' : 'verified');
			}
		);
	}
});

test('parameter acceptance differs from observed parallel tool calls; calls are never executed', async () => {
	await withDiagnostics(
		(body, response) => {
			if (body.tools) complete(response, '', ['probe_left', 'probe_right']);
			else complete(response);
		},
		async (config) => {
			const result = await runCapabilityDiagnostics(config, { log: () => {} });
			assert.equal(result.exitCode, 0);
			assert.equal(result.checks.find((check) => check.name === 'parallel').status, 'verified');
			assert.equal(result.checks.find((check) => check.name === 'verbosity').status, 'parameter_accepted');
		},
		{ supportsImageInput: false, supportsParallelToolCalls: true, supportVerbosity: true, defaultVerbosity: 'low' }
	);
	await withDiagnostics(
		(body, response) => complete(response, body.tools ? '' : 'OK', body.tools ? ['probe_left'] : []),
		async (config) => {
			const result = await runCapabilityDiagnostics(config, { log: () => {} });
			assert.equal(result.exitCode, 2);
			assert.equal(result.checks.at(-1).status, 'inconclusive');
		},
		{ supportsImageInput: false, supportsParallelToolCalls: true }
	);
});

test('diagnostics stop after a failed control and preserve sanitized failure evidence', async () => {
	let calls = 0;
	await withDiagnostics(
		(_body, response) => {
			calls++;
			response.writeHead(401, { 'content-type': 'application/json' });
			response.end(JSON.stringify({ error: { code: 'authentication_error', message: 'Bad Bearer secret-test-key' } }));
		},
		async (config) => {
			const result = await runCapabilityDiagnostics(config, { log: () => {} });
			assert.equal(calls, 1);
			assert.equal(result.exitCode, 2);
			assert.equal(result.checks[0].status, 'provider_error');
			const saved = await readFile(result.reportPath, 'utf8');
			assert.ok(!saved.includes('secret-test-key'));
		}
	);
});

test('truncated SSE, timeout and cancellation are not unsupported capabilities', async () => {
	const check = { kind: 'image', expected: 'RED,GREEN,BLUE,CYAN', body: { input: [] } };
	const server = http.createServer((_request, response) => {
		response.writeHead(200, { 'content-type': 'text/event-stream' });
		event(response, 'response.output_text.delta', { delta: check.expected });
		response.end();
	});
	const url = await listen(server);
	try {
		const result = await probeCapability(url, check);
		assert.equal(result.status, 'invalid_response');
	} finally {
		await close(server);
	}
	const stalled = http.createServer(() => {});
	const stalledUrl = await listen(stalled);
	try {
		const timeout = await probeCapability(stalledUrl, check, { timeoutMs: 20 });
		assert.equal(timeout.status, 'timeout');
		const abort = new AbortController();
		abort.abort();
		const cancelled = await probeCapability(stalledUrl, check, { signal: abort.signal });
		assert.equal(cancelled.status, 'cancelled');
	} finally {
		await close(stalled);
	}
});

test('explicit parallel override is transported even when the caller sends the opposite value', async () => {
	let received;
	const upstream = http.createServer(async (request, response) => {
		let raw = '';
		for await (const chunk of request) raw += chunk;
		received = JSON.parse(raw);
		complete(response);
	});
	const upstreamBaseUrl = await listen(upstream);
	const router = createShellRouterServer({
		logger: () => {},
		routes: [
			{
				clientModel: 'capability-probe',
				upstreamModel: 'mimo-v2.6-pro',
				upstreamBaseUrl,
				apiKey: 'key',
				parallelToolCalls: false,
				responsesAdapter: 'mimo-textual-tools'
			}
		]
	});
	const url = await listen(router);
	try {
		await probeCapability(url, {
			kind: 'parameter',
			body: {
				parallel_tool_calls: true,
				input: [{ role: 'user', content: [{ type: 'input_image', image_url: createVisionChallenge().imageUrl }] }]
			}
		});
		assert.equal(received.parallel_tool_calls, false);
		assert.equal(received.input[0].content[0].type, 'input_image');
	} finally {
		await close(router);
		await close(upstream);
	}
	assert.throws(
		() =>
			createShellRouterServer({
				routes: [{ clientModel: 'x', upstreamModel: 'x', upstreamBaseUrl, apiKey: 'key', parallelToolCalls: 'false' }]
			}),
		/Boolean/
	);
});

test('classifications, fingerprints and request budgets retain their distinct meanings', () => {
	assert.equal(classifyCapabilityError(400, { message: 'Unsupported input_image' }).status, 'unsupported');
	assert.equal(classifyCapabilityError(429, { message: 'Rate limit for vision' }).status, 'provider_error');
	assert.equal(capabilityExitCode([{ status: 'wrong_answer' }, { status: 'timeout' }]), 2);
	const model = { registryId: 'mimo', model: 'mimo-v2.6-pro', capabilities: DEFAULT_CAPABILITIES };
	assert.equal(capabilityFingerprint(model), capabilityFingerprint({ ...model, apiKey: 'different-key' }));
	assert.notEqual(capabilityFingerprint(model), capabilityFingerprint({ ...model, responsesAdapter: 'other' }));
	const checks = buildCapabilityChecks(DEFAULT_CAPABILITIES);
	assert.equal(checks[0].body.reasoning.effort, 'none');
	assert.equal(checks.find((check) => check.name === 'reasoning').body.reasoning.effort, 'high');
});
