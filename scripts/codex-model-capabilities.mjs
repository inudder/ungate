import { createHash, randomInt, randomUUID } from 'node:crypto';
import { mkdir, readFile, readdir, rename, writeFile } from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateSync } from 'node:zlib';

import { createBridgeServer } from './cliproxy-namespace-bridge.mjs';
import { createShellRouterServer } from './codex-model-shell-router.mjs';

const PALETTE = {
	RED: [255, 0, 0],
	GREEN: [0, 190, 0],
	BLUE: [0, 0, 255],
	YELLOW: [255, 255, 0],
	MAGENTA: [255, 0, 255],
	CYAN: [0, 255, 255]
};

function crc32(bytes) {
	let value = 0xffffffff;
	for (const byte of bytes) {
		value ^= byte;
		for (let bit = 0; bit < 8; bit++) value = (value >>> 1) ^ (0xedb88320 & -(value & 1));
	}

	return (value ^ 0xffffffff) >>> 0;
}

function pngChunk(type, bytes) {
	const name = Buffer.from(type);
	const chunk = Buffer.alloc(bytes.length + 12);
	chunk.writeUInt32BE(bytes.length);
	name.copy(chunk, 4);
	bytes.copy(chunk, 8);
	chunk.writeUInt32BE(crc32(Buffer.concat([name, bytes])), bytes.length + 8);

	return chunk;
}

export function createVisionChallenge(colors) {
	if (!colors) {
		const choices = Object.keys(PALETTE);
		colors = Array.from({ length: 4 }, () => choices.splice(randomInt(choices.length), 1)[0]);
	}
	if (colors.length !== 4 || colors.some((color) => !PALETTE[color])) throw new Error('Expected four palette colors.');
	const width = 128;
	const height = 64;
	const rows = Buffer.alloc((width * 3 + 1) * height);
	for (let y = 0; y < height; y++) {
		for (let x = 0; x < width; x++) {
			const rgb = PALETTE[colors[Math.floor(x / 32)]];
			for (let channel = 0; channel < 3; channel++) rows[y * (width * 3 + 1) + 1 + x * 3 + channel] = rgb[channel];
		}
	}
	const header = Buffer.alloc(13);
	header.writeUInt32BE(width);
	header.writeUInt32BE(height, 4);
	header[8] = 8;
	header[9] = 2;
	const png = Buffer.concat([
		Buffer.from('89504e470d0a1a0a', 'hex'),
		pngChunk('IHDR', header),
		pngChunk('IDAT', deflateSync(rows)),
		pngChunk('IEND', Buffer.alloc(0))
	]);

	return { imageUrl: `data:image/png;base64,${png.toString('base64')}`, expected: colors.join(',') };
}

function stable(value) {
	if (Array.isArray(value)) return value.map(stable);
	if (value && typeof value === 'object')
		return Object.fromEntries(
			Object.keys(value)
				.sort()
				.map((key) => [key, stable(value[key])])
		);

	return value;
}

export function capabilitySnapshot(model) {
	return stable({
		registryId: model.registryId,
		model: model.model,
		upstreamBaseUrl: model.upstreamBaseUrl,
		responsesAdapter: model.responsesAdapter ?? null,
		bridgeUpstreamUrl: model.bridgeUpstreamUrl ?? null,
		parallelToolCalls: model.parallelToolCalls ?? null,
		capabilities: model.capabilities
	});
}

export function capabilityFingerprint(model) {
	return createHash('sha256')
		.update(JSON.stringify(capabilitySnapshot(model)))
		.digest('hex');
}

export function classifyCapabilityError(httpStatus, error) {
	const reason = String(error?.message ?? error?.code ?? `HTTP ${httpStatus}`);
	const details = `${error?.code ?? ''} ${error?.type ?? ''} ${error?.param ?? ''} ${reason}`;
	const transport = /auth|api.?key|rate.?limit|quota|overload|timeout|server_error|upstream_unavailable/i.test(details);
	const feature = /image|vision|original|modalit|reasoning|verbosity|parallel_tool_calls/i.test(details);
	const rejected = /invalid|unsupported|not supported|not allowed|not permitted|unknown|reject/i.test(details);

	return {
		status: !transport && [200, 400, 422].includes(httpStatus) && feature && rejected ? 'unsupported' : 'provider_error',
		reason
	};
}

function requestLocal(url, body, signal) {
	return new Promise((resolve, reject) => {
		const request = http.request(
			url,
			{
				method: body ? 'POST' : 'GET',
				signal,
				headers: body ? { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) } : {}
			},
			resolve
		);
		request.once('error', reject);
		request.end(body);
	});
}

export async function probeCapability(baseUrl, check, { signal, timeoutMs = 120000 } = {}) {
	const started = Date.now();
	const requestSignal = signal ? AbortSignal.any([signal, AbortSignal.timeout(timeoutMs)]) : AbortSignal.timeout(timeoutMs);
	try {
		const response = await requestLocal(
			`${baseUrl}/v1/responses`,
			JSON.stringify({ model: 'capability-probe', stream: true, max_output_tokens: 512, ...check.body }),
			requestSignal
		);
		let buffer = '';
		let text = '';
		let terminal = null;
		let invalid = false;
		let responseError = null;
		let bytes = 0;
		const tools = new Map();
		function collectItem(item) {
			if (item?.type === 'function_call') tools.set(item.call_id ?? item.id ?? item.name, item.name);
		}
		function event(block) {
			const data = block
				.split('\n')
				.filter((line) => line.startsWith('data:'))
				.map((line) => line.slice(5).trimStart())
				.join('\n');
			if (!data || data === '[DONE]') return;
			let frame;
			try {
				frame = JSON.parse(data);
			} catch {
				invalid = true;

				return;
			}
			if (frame.type === 'error' || frame.type === 'response.failed' || frame.error || frame.response?.error) {
				responseError = frame.error ?? frame.response?.error ?? frame;
			}
			if (frame.type === 'response.output_text.delta') text += frame.delta ?? '';
			if (frame.type === 'response.output_item.done') collectItem(frame.item);
			if (frame.type === 'response.completed' || frame.type === 'response.incomplete') {
				terminal = frame;
				for (const item of frame.response?.output ?? []) collectItem(item);
				if (!text)
					text = (frame.response?.output ?? [])
						.flatMap((item) => item.content ?? [])
						.filter((part) => part.type === 'output_text')
						.map((part) => part.text)
						.join('');
			}
		}
		response.setEncoding('utf8');
		for await (const chunk of response) {
			bytes += Buffer.byteLength(chunk);
			if (bytes > 4 * 1024 * 1024) {
				response.destroy();

				return { status: 'invalid_response', reason: 'Response exceeded 4 MiB.' };
			}
			buffer += chunk;
			if (/text\/event-stream/i.test(response.headers['content-type'] ?? '')) {
				buffer = buffer.replace(/\r\n/g, '\n');
				let boundary;
				while ((boundary = buffer.indexOf('\n\n')) >= 0) {
					event(buffer.slice(0, boundary));
					buffer = buffer.slice(boundary + 2);
				}
			}
		}
		const httpStatus = response.statusCode;
		if (httpStatus < 200 || httpStatus >= 300 || responseError) {
			if (!responseError) {
				try {
					const value = JSON.parse(buffer);
					responseError = value.error ?? value;
				} catch {
					responseError = { message: `HTTP ${httpStatus}` };
				}
			}

			return { ...classifyCapabilityError(httpStatus, responseError), httpStatus, durationMs: Date.now() - started };
		}
		if (invalid || !terminal || buffer.trim())
			return {
				status: 'invalid_response',
				reason: 'Missing or invalid Responses terminal event.',
				durationMs: Date.now() - started
			};
		const complete = terminal.type === 'response.completed' && terminal.response?.status === 'completed';
		const tokenLimit =
			terminal.type === 'response.incomplete' && terminal.response?.incomplete_details?.reason === 'max_output_tokens';
		let result;
		if (check.kind === 'parameter' && (complete || tokenLimit))
			result = { status: 'parameter_accepted', reason: 'Параметр принят; влияние на поведение не доказано.' };
		else if (!complete) result = { status: 'inconclusive', reason: 'Response did not complete.' };
		else if (check.kind === 'image') {
			const color = 'RED|GREEN|BLUE|YELLOW|MAGENTA|CYAN';
			const answerLine = new RegExp(`^(?:${color})(?:\\s*,\\s*(?:${color})){3}[.!]?$`);
			const finalAnswer = text
				.toUpperCase()
				.split('\n')
				.map((line) => line.replace(/[*_`]/g, '').trim())
				.filter((line) => answerLine.test(line))
				.at(-1);
			const observed = ((finalAnswer ?? text.toUpperCase()).match(new RegExp(`\\b(?:${color})\\b`, 'g')) ?? []).join(',');
			result = {
				status: observed === check.expected ? 'verified' : 'wrong_answer',
				expected: check.expected,
				observed,
				reason: observed === check.expected ? 'Содержимое PNG распознано.' : 'Ответ не совпал с содержимым PNG.'
			};
		} else if (check.kind === 'parallel') {
			const names = [...tools.values()];
			result = {
				status: names.includes('probe_left') && names.includes('probe_right') ? 'verified' : 'inconclusive',
				reason:
					names.includes('probe_left') && names.includes('probe_right')
						? 'Два независимых вызова получены в одном ответе; функции не исполнялись.'
						: 'Два вызова не наблюдались; отказ поддержки не доказан.'
			};
		} else result = { status: text.trim() ? 'verified' : 'inconclusive', reason: 'Контрольный запрос завершён.' };

		return { ...result, httpStatus, durationMs: Date.now() - started };
	} catch (error) {
		let status = 'provider_error';
		if (signal?.aborted) status = 'cancelled';
		else if (requestSignal.aborted) status = 'timeout';

		return { status, reason: String(error.message), durationMs: Date.now() - started };
	}
}

async function listenOwned(server, healthPath, service) {
	await new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen({ host: '127.0.0.1', port: 0, exclusive: true }, resolve);
	});
	const baseUrl = `http://127.0.0.1:${server.address().port}`;
	const response = await requestLocal(`${baseUrl}${healthPath}`, undefined, AbortSignal.timeout(5000));
	let body = '';
	for await (const part of response) body += part;
	const health = JSON.parse(body);
	if (response.statusCode !== 200 || health.pid !== process.pid || health.service !== service)
		throw new Error('Diagnostic server identity check failed.');

	return baseUrl;
}

async function closeOwned(server) {
	if (!server.listening) return;
	await new Promise((resolve) => {
		server.close(resolve);
		server.closeAllConnections();
	});
}

async function saveReport(filename, report) {
	await mkdir(path.dirname(filename), { recursive: true });
	const temporary = `${filename}.${randomUUID()}.tmp`;
	await writeFile(temporary, JSON.stringify(report, null, 2) + '\n');
	// A failed write/rename preserves the previous report and temporary evidence.
	await rename(temporary, filename);
}

export function buildCapabilityChecks(capabilities) {
	const input = [{ role: 'user', content: 'Reply OK.' }];
	const efforts = capabilities.supportedReasoningLevels;
	const shortEffort = ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'].find((level) =>
		efforts.includes(level)
	);
	const checks = [{ name: 'control', kind: 'control', body: { input, reasoning: { effort: shortEffort } } }];
	if (capabilities.supportsImageInput) {
		for (const detail of capabilities.supportsImageDetailOriginal ? ['auto', 'original'] : ['auto']) {
			const challenge = createVisionChallenge();
			checks.push({
				name: `image:${detail}`,
				kind: 'image',
				expected: challenge.expected,
				body: {
					reasoning: { effort: shortEffort },
					input: [
						{
							role: 'user',
							content: [
								{
									type: 'input_text',
									text: 'Name the four colored vertical bands from left to right. Use only comma-separated uppercase English color names. Available names: RED, GREEN, BLUE, YELLOW, MAGENTA, CYAN.'
								},
								{ type: 'input_image', image_url: challenge.imageUrl, detail }
							]
						}
					]
				}
			});
		}
	}
	checks.push({
		name: 'reasoning',
		kind: 'parameter',
		body: { input, reasoning: { effort: capabilities.defaultReasoningLevel } }
	});
	if (capabilities.supportsReasoningSummaries && capabilities.defaultReasoningSummary !== 'none') {
		checks.push({
			name: 'reasoning-summary',
			kind: 'parameter',
			body: { input, reasoning: { effort: capabilities.defaultReasoningLevel, summary: capabilities.defaultReasoningSummary } }
		});
	}
	if (capabilities.supportVerbosity)
		checks.push({ name: 'verbosity', kind: 'parameter', body: { input, text: { verbosity: capabilities.defaultVerbosity } } });
	if (capabilities.supportsParallelToolCalls)
		checks.push({
			name: 'parallel',
			kind: 'parallel',
			body: {
				input: [
					{
						role: 'user',
						content:
							'Call both independent diagnostic functions probe_left and probe_right in the same response. Do not answer in text.'
					}
				],
				reasoning: { effort: shortEffort },
				parallel_tool_calls: true,
				tool_choice: 'required',
				tools: ['probe_left', 'probe_right'].map((name) => ({
					type: 'function',
					name,
					description: 'Independent inert diagnostic function.',
					parameters: { type: 'object', properties: {}, additionalProperties: false }
				}))
			}
		});

	return checks;
}

export function capabilityExitCode(checks) {
	if (
		!checks.length ||
		checks.some((check) => ['provider_error', 'timeout', 'cancelled', 'invalid_response', 'inconclusive'].includes(check.status))
	)
		return 2;
	if (checks.some((check) => ['unsupported', 'wrong_answer'].includes(check.status))) return 1;

	return 0;
}

export async function runCapabilityDiagnostics(config, { signal, timeoutMs = 120000, log = console.log } = {}) {
	const model = config.model;
	const checks = buildCapabilityChecks(model.capabilities);
	const overall = AbortSignal.timeout(timeoutMs * (checks.length + 1) + 10000);
	const boundedSignal = signal ? AbortSignal.any([signal, overall]) : overall;
	const report = {
		version: 1,
		startedAt: new Date().toISOString(),
		completedAt: null,
		snapshot: capabilitySnapshot(model),
		fingerprint: capabilityFingerprint(model),
		checks: []
	};
	const reportPath = path.join(config.reportDirectory, `${report.startedAt.replace(/[:.]/g, '-')}_${randomUUID()}.json`);
	const servers = [];
	function sanitize(value) {
		let text = String(value);
		if (model.apiKey) text = text.replaceAll(model.apiKey, '[REDACTED]');

		return text.replace(/Bearer\s+\S+/gi, 'Bearer [REDACTED]');
	}
	log(`Отчёт: ${reportPath}`);
	await saveReport(reportPath, report);
	try {
		if (!model.apiKey) throw new Error('Provider credentials are missing.');
		let upstreamBaseUrl = model.upstreamBaseUrl;
		if (model.bridgeUpstreamUrl) {
			const bridge = createBridgeServer({ upstreamUrl: model.bridgeUpstreamUrl });
			servers.push(bridge);
			upstreamBaseUrl = await listenOwned(bridge, '/_bridge/health', 'cliproxy-namespace-bridge');
		}
		const router = createShellRouterServer({
			logger: () => {},
			routes: [
				{
					clientModel: 'capability-probe',
					upstreamModel: model.model,
					upstreamBaseUrl,
					apiKey: model.apiKey,
					responsesAdapter: model.responsesAdapter,
					parallelToolCalls: model.parallelToolCalls
				}
			]
		});
		servers.push(router);
		const baseUrl = await listenOwned(router, '/_shell-router/health', 'codex-model-shell-router');
		for (const check of checks) {
			const result = await probeCapability(baseUrl, check, { signal: boundedSignal, timeoutMs });
			result.reason = sanitize(result.reason);
			report.checks.push({ name: check.name, ...result });
			log(`${check.name}: ${result.status} — ${result.reason}`);
			await saveReport(reportPath, report);
			if ((check.name === 'control' && result.status !== 'verified') || boundedSignal.aborted) break;
		}
	} catch (error) {
		report.checks.push({
			name: 'transport',
			status: signal?.aborted ? 'cancelled' : 'provider_error',
			reason: sanitize(error.message)
		});
	} finally {
		for (const server of servers.reverse()) await closeOwned(server);
		report.completedAt = new Date().toISOString();
		report.exitCode = capabilityExitCode(report.checks);
		await saveReport(reportPath, report);
	}

	return { ...report, reportPath };
}

export async function reportStatus(config) {
	let files;
	try {
		const entries = await readdir(config.reportDirectory);
		files = entries
			.filter((name) => name.endsWith('.json'))
			.sort()
			.reverse();
	} catch (error) {
		if (error.code === 'ENOENT') return 'Проверка: ещё не запускалась.';
		throw error;
	}
	for (const filename of files) {
		let report;
		try {
			const content = await readFile(path.join(config.reportDirectory, filename), 'utf8');
			report = JSON.parse(content);
		} catch {
			continue;
		}
		if (report.snapshot?.registryId !== config.model.registryId) continue;
		if (report.fingerprint !== capabilityFingerprint(config.model))
			return 'Проверка: устарела — маршрут или возможности изменены.';
		if (!report.completedAt) return 'Проверка: не завершена.';

		return `Проверка: ${report.completedAt}; код ${report.exitCode}.`;
	}

	return 'Проверка: ещё не запускалась.';
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	const controller = new AbortController();
	process.once('SIGINT', () => controller.abort());
	process.once('SIGTERM', () => controller.abort());
	try {
		let input = '';
		for await (const chunk of process.stdin) {
			input += chunk;
			if (input.length > 1024 * 1024) throw new Error('Configuration exceeds 1 MiB.');
		}
		const config = JSON.parse(input);
		if (process.argv.includes('--status')) {
			const status = await reportStatus(config);
			console.log(status);
		} else {
			const result = await runCapabilityDiagnostics(config, { signal: controller.signal });
			process.exitCode = result.exitCode;
		}
	} catch {
		console.error('Capability diagnostic failed; preserved reports and configuration.');
		process.exitCode = 2;
	}
}
