import http from 'node:http';
import { fileURLToPath } from 'node:url';

import { createBridgeServer } from './cliproxy-namespace-bridge.mjs';
import { createShellRouterServer } from './codex-model-shell-router.mjs';

function requestJson(url, { body, apiKey, signal } = {}) {
	return new Promise((resolve, reject) => {
		const encoded = body ? JSON.stringify(body) : null;
		const headers = apiKey ? { authorization: `Bearer ${apiKey}` } : {};
		if (encoded) headers['content-type'] = 'application/json';
		const request = http.request(url, { method: encoded ? 'POST' : 'GET', headers, signal, agent: false }, (response) => {
			let text = '';
			response.setEncoding('utf8');
			response.on('data', (chunk) => {
				text += chunk;
				if (text.length > 2 * 1024 * 1024) request.destroy(new Error('response_too_large'));
			});
			response.on('error', reject);
			response.on('end', () =>
				resolve({ status: response.statusCode, contentType: response.headers['content-type'] ?? '', text })
			);
		});
		request.on('error', reject);
		request.end(encoded);
	});
}

async function listenOwned(server, path, service) {
	await new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen({ host: '127.0.0.1', port: 0, exclusive: true }, resolve);
	});
	const baseUrl = `http://127.0.0.1:${server.address().port}`;
	const result = await requestJson(`${baseUrl}${path}`, { signal: AbortSignal.timeout(5000) });
	const health = JSON.parse(result.text);
	if (result.status !== 200 || health.pid !== process.pid || health.service !== service) throw new Error('server_identity');

	return baseUrl;
}

async function closeOwned(server) {
	if (!server.listening) return;
	await new Promise((resolve) => {
		server.close(resolve);
		server.closeAllConnections();
	});
}

export function parseMemoryResponse(result) {
	if (result.status < 200 || result.status >= 300) throw new Error(`http_${result.status}`);
	if (!result.contentType.includes('text/event-stream')) throw new Error('expected_sse');
	const blocks = result.text.replaceAll('\r\n', '\n').split('\n\n');
	if (blocks.pop().trim()) throw new Error('incomplete_sse');
	let completed = null;
	const active = new Set();
	let created = false;
	for (const block of blocks) {
		const data = block
			.split('\n')
			.filter((line) => line.startsWith('data:'))
			.map((line) => line.slice(5).trimStart())
			.join('\n');
		if (!data || data === '[DONE]') continue;
		const event = JSON.parse(data);
		if (event.type === 'error' || event.type === 'response.failed' || event.type === 'response.incomplete')
			throw new Error('terminal_error');
		if (completed) throw new Error('event_after_completion');
		if (event.type === 'response.created') created = true;
		if (event.type === 'response.output_item.added') active.add(event.item?.id);
		if (event.type?.endsWith('.delta') && (!created || !active.has(event.item_id))) throw new Error('invalid_sse_lifecycle');
		if (event.type === 'response.completed') completed = event.response;
	}
	if (!created || completed?.status !== 'completed' || !Array.isArray(completed.output)) throw new Error('incomplete_sse');

	return completed;
}

function outputText(response) {
	return response.output
		.filter((item) => item.type === 'message')
		.flatMap((item) => item.content ?? [])
		.filter((content) => content.type === 'output_text')
		.map((content) => content.text)
		.join('');
}

export function verifyMemoryStage(stage, response) {
	if (stage === 'extraction') {
		const value = JSON.parse(outputText(response));
		if (value.memory !== 'Use PowerShell' || Object.keys(value).length !== 1) throw new Error('invalid_structured_output');
	} else if (stage === 'function') {
		const calls = response.output.filter((item) => item.type === 'function_call');
		if (calls.length !== 1 || calls[0].namespace !== 'memory_probe' || calls[0].name !== 'remember' || !calls[0].call_id)
			throw new Error('invalid_function_call');
		const value = JSON.parse(calls[0].arguments);
		if (value.memory !== 'Use PowerShell' || Object.keys(value).length !== 1) throw new Error('invalid_function_arguments');

		return calls[0];
	} else if (stage === 'custom') {
		const calls = response.output.filter((item) => item.type === 'custom_tool_call');
		if (calls.length !== 1 || calls[0].name !== 'exec' || !calls[0].call_id || calls[0].input.trim() !== 'return "OK";')
			throw new Error('invalid_custom_call');

		return calls[0];
	} else if (outputText(response).trim().replace(/\.$/, '') !== 'OK') throw new Error('invalid_continuation');

	return null;
}

export async function runMemoryPreflight(config, { timeoutMs = 120000, signal, log = () => {} } = {}) {
	const servers = [];
	const lifetime = AbortSignal.timeout(600000);
	const runSignal = signal ? AbortSignal.any([signal, lifetime]) : lifetime;
	let stage = 'catalog';
	try {
		let catalogPresent = null;
		try {
			const catalog = await requestJson(`${config.bridgeUpstreamUrl ?? config.upstreamBaseUrl}/v1/models`, {
				apiKey: config.apiKey,
				signal: AbortSignal.any([runSignal, AbortSignal.timeout(10000)])
			});
			if (catalog.status === 401 || catalog.status === 403) throw new Error(`http_${catalog.status}`);
			if (catalog.status === 200) catalogPresent = JSON.parse(catalog.text).data.some((item) => item.id === config.model);
		} catch (error) {
			if (/^http_(401|403)$/.test(error.message)) throw error;
			log('catalog_advisory_unavailable');
		}
		stage = 'transport';
		let upstreamBaseUrl = config.upstreamBaseUrl;
		if (config.bridgeUpstreamUrl) {
			const bridge = createBridgeServer({ upstreamUrl: config.bridgeUpstreamUrl, logger: { log() {}, warn() {}, error() {} } });
			servers.push(bridge);
			upstreamBaseUrl = await listenOwned(bridge, '/_bridge/health', 'cliproxy-namespace-bridge');
		}
		const router = createShellRouterServer({
			routes: [
				{
					clientModel: 'ungate-memory',
					upstreamModel: config.model,
					upstreamBaseUrl,
					apiKey: config.apiKey,
					responsesAdapter: config.responsesAdapter
				}
			],
			logger: () => {}
		});
		servers.push(router);
		const baseUrl = await listenOwned(router, '/_shell-router/health', 'codex-model-shell-router');
		const invoke = async (body) => {
			log(stage);
			const result = await requestJson(`${baseUrl}/v1/responses`, {
				body: { model: 'ungate-memory', stream: true, store: false, max_output_tokens: 4096, ...body },
				signal: AbortSignal.any([runSignal, AbortSignal.timeout(timeoutMs)])
			});
			const response = parseMemoryResponse(result);

			return { response, call: verifyMemoryStage(stage, response) };
		};
		stage = 'extraction';
		await invoke({
			input: 'Extract this memory: Use PowerShell. Return exactly {"memory":"Use PowerShell"}.',
			text: {
				format: {
					type: 'json_schema',
					name: 'memory_probe',
					strict: true,
					schema: {
						type: 'object',
						properties: { memory: { type: 'string' } },
						required: ['memory'],
						additionalProperties: false
					}
				}
			}
		});
		stage = 'function';
		const tools = [
			{
				type: 'namespace',
				name: 'memory_probe',
				tools: [
					{
						type: 'function',
						name: 'remember',
						description: 'Record the synthetic memory.',
						parameters: {
							type: 'object',
							properties: { memory: { type: 'string' } },
							required: ['memory'],
							additionalProperties: false
						}
					}
				]
			}
		];
		const functionInput = [
			{
				role: 'user',
				content: 'Call memory_probe.remember exactly once with these exact arguments: {"memory":"Use PowerShell"}'
			}
		];
		const functionResult = await invoke({
			input: functionInput,
			tools,
			parallel_tool_calls: false,
			tool_choice: { type: 'function', namespace: 'memory_probe', name: 'remember' }
		});
		stage = 'custom';
		const customTools = [
			{ type: 'custom', name: 'exec', description: 'Accept JavaScript source. For this probe use exactly return "OK";' }
		];
		const customInput = [{ role: 'user', content: 'Call exec once with this exact input: return "OK";' }];
		const customResult = await invoke({ input: customInput, tools: customTools, tool_choice: { type: 'custom', name: 'exec' } });
		stage = 'continuation';
		await invoke({
			input: [
				...functionInput,
				...functionResult.response.output,
				{ type: 'function_call_output', call_id: functionResult.call.call_id, output: 'OK' },
				{ role: 'user', content: 'The synthetic tool succeeded. Reply with exactly OK.' }
			],
			tools,
			tool_choice: 'none'
		});
		await invoke({
			input: [
				...customInput,
				...customResult.response.output,
				{ type: 'custom_tool_call_output', call_id: customResult.call.call_id, output: 'OK' },
				{ role: 'user', content: 'The synthetic tool succeeded. Reply with exactly OK.' }
			],
			tools: customTools,
			tool_choice: 'none'
		});

		return { valid: true, stage: 'complete', catalogPresent };
	} catch (error) {
		const code = /^[a-z_]+(?:_\d+)?$/.test(error.message) ? error.message : 'invalid_response';

		return { valid: false, stage, code: error.name === 'AbortError' ? 'timeout_or_cancelled' : code };
	} finally {
		for (const server of servers.reverse()) await closeOwned(server);
	}
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
	let input = '';
	for await (const chunk of process.stdin) input += chunk;
	try {
		const result = await runMemoryPreflight(JSON.parse(input), { log: (stage) => process.stderr.write(`[memory] ${stage}\n`) });
		process.stdout.write(`${JSON.stringify(result)}\n`);
		process.exitCode = result.valid ? 0 : 2;
	} catch {
		process.stdout.write('{"valid":false,"stage":"configuration","code":"invalid_configuration"}\n');
		process.exitCode = 2;
	}
}
