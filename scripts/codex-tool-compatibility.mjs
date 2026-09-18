import { randomUUID } from 'node:crypto';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { createBridgeServer } from './cliproxy-namespace-bridge.mjs';
import { createShellRouterServer } from './codex-model-shell-router.mjs';
import { ensureToolsSnapshot, readToolsSnapshot, writeJsonAtomic } from './codex-tools-schema-cache.mjs';

const CACHE_HELP = 'Перезапустите Beta через обновлённый launcher, отправьте сообщение и повторите TT.';
const LABELS = {
	accepted: 'СХЕМА ПРИНЯТА',
	schema_rejected: 'ОТКАЗ СХЕМЫ',
	timeout: 'ТАЙМАУТ',
	provider_error: 'ОШИБКА ПРОВАЙДЕРА/ТРАНСПОРТА',
	invalid_response: 'НЕКОРРЕКТНЫЙ ОТВЕТ',
	cancelled: 'ОТМЕНЕНО'
};

export function individualTools(tools, prefix = '') {
	return tools.flatMap((tool) => {
		const name = `${prefix}${tool.name ?? tool.type}`;
		if (tool.type !== 'namespace') return [{ name, tools: [tool] }];
		const key = Array.isArray(tool.tools) ? 'tools' : 'functions';

		return individualTools(tool[key], `${name}.`).map((child) => ({
			name: child.name,
			tools: [{ ...tool, [key]: child.tools }]
		}));
	});
}

function errorMessage(error) {
	return String(error?.message ?? error?.code ?? 'Provider rejected the request.');
}

export function classifyError(status, error) {
	const message = errorMessage(error);
	const detail = `${error?.code ?? ''} ${error?.param ?? ''} ${message}`;
	const toolRelated =
		/\btools(?:\b|[.\[])|\btool\b|\bnamespace\b|\b(?:function|custom)[._ ](?:parameters|schema|tool)|invalid_function_parameters/i.test(
			detail
		);
	const rejection =
		/invalid|unsupported|not supported|not permitted|not allowed|schema|must be|requires?|additional propert|collid|collision|duplicate/i.test(
			detail
		);
	const providerFailure = /auth|api[_ ]?key|rate[_ ]?limit|quota|overload|timeout|server_error|upstream_unavailable/i.test(
		`${error?.code ?? ''} ${error?.type ?? ''}`
	);
	const schemaRejected = [200, 400, 422].includes(status) && !providerFailure && toolRelated && rejection;

	return { status: schemaRejected ? 'schema_rejected' : 'provider_error', reason: message };
}

// No fetch/proxy environment: all diagnostic connections target servers owned by this process.
function localRequest(url, { body, signal, onResponse } = {}) {
	return new Promise((resolve, reject) => {
		const request = http.request(
			url,
			{
				method: body ? 'POST' : 'GET',
				signal,
				agent: false,
				headers: body ? { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) } : {}
			},
			(response) => {
				if (onResponse) onResponse(response, resolve, reject);
				else {
					let value = '';
					response.on('data', (chunk) => {
						value += chunk;
					});
					response.on('end', () => resolve({ status: response.statusCode, value }));
					response.on('error', reject);
				}
			}
		);
		request.on('error', reject);
		request.end(body);
	});
}

export async function probeSchema(baseUrl, model, tools, { signal, timeoutMs = 120000 } = {}) {
	const started = Date.now();
	const timeout = AbortSignal.timeout(timeoutMs);
	const combined = signal ? AbortSignal.any([signal, timeout]) : timeout;
	try {
		const result = await localRequest(`${baseUrl}/v1/responses`, {
			signal: combined,
			body: JSON.stringify({
				model,
				input: [{ role: 'user', content: 'Reply OK. Do not use any tools.' }],
				stream: true,
				max_output_tokens: 512,
				...(tools.length ? { tools, tool_choice: 'none' } : {})
			}),
			onResponse(response, resolve, reject) {
				const httpStatus = response.statusCode;
				const streaming = /text\/event-stream/i.test(response.headers['content-type'] ?? '');
				let buffer = '';
				let bytes = 0;
				let terminal = null;
				let invalid = false;
				const event = (block) => {
					const data = block
						.split('\n')
						.filter((line) => line.startsWith('data:'))
						.map((line) => line.slice(5).trimStart())
						.join('\n');
					if (!data || data === '[DONE]') return;
					let value;
					try {
						value = JSON.parse(data);
					} catch {
						invalid = true;

						return;
					}
					if (value.type === 'error' || value.type === 'response.failed' || value.error || value.response?.error) {
						terminal = classifyError(httpStatus, value.error ?? value.response?.error ?? value);
					} else if (value.type === 'response.completed' && value.response?.status === 'completed') {
						terminal ??= { status: 'accepted', reason: 'Request completed; schema accepted (tool execution not tested).' };
					} else if (value.type === 'response.incomplete') {
						terminal ??=
							value.response?.incomplete_details?.reason === 'max_output_tokens'
								? { status: 'accepted', reason: 'Output token limit reached; schema accepted (tool execution not tested).' }
								: { status: 'invalid_response', reason: 'Response is incomplete.' };
					}
				};
				response.setEncoding('utf8');
				response.on('data', (chunk) => {
					bytes += Buffer.byteLength(chunk);
					if (bytes > 4 * 1024 * 1024) {
						resolve({ status: 'invalid_response', reason: 'Diagnostic response exceeded 4 MiB.' });
						response.destroy();

						return;
					}
					buffer += chunk;
					if (streaming) {
						buffer = buffer.replace(/\r\n/g, '\n');
						let boundary;
						while ((boundary = buffer.indexOf('\n\n')) >= 0) {
							event(buffer.slice(0, boundary));
							buffer = buffer.slice(boundary + 2);
						}
					}
				});
				response.on('end', () => {
					if (httpStatus < 200 || httpStatus >= 300) {
						if (streaming && terminal && terminal.status !== 'accepted') {
							resolve({ ...terminal, httpStatus });

							return;
						}
						let error;
						try {
							const value = JSON.parse(buffer);
							error = value.error ?? value;
						} catch {
							error = { message: `HTTP ${httpStatus}` };
						}
						resolve({ ...classifyError(httpStatus, error), httpStatus });
					} else if (!streaming || invalid || !terminal || buffer.trim()) {
						resolve({
							status: 'invalid_response',
							httpStatus,
							reason: 'Expected a complete Responses SSE stream with a terminal event.'
						});
					} else resolve({ ...terminal, httpStatus });
				});
				response.on('error', reject);
			}
		});

		return { ...result, durationMs: Date.now() - started };
	} catch (error) {
		let status = 'provider_error';
		let reason = errorMessage(error);
		if (signal?.aborted) {
			status = 'cancelled';
			reason = 'Test cancelled.';
		} else if (timeout.aborted) {
			status = 'timeout';
			reason = 'Request exceeded its timeout.';
		}

		return {
			status,
			reason,
			durationMs: Date.now() - started
		};
	}
}

async function listenOwned(server, healthPath, service) {
	await new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen({ host: '127.0.0.1', port: 0, exclusive: true }, resolve);
	});
	const baseUrl = `http://127.0.0.1:${server.address().port}`;
	const health = await localRequest(`${baseUrl}${healthPath}`, { signal: AbortSignal.timeout(5000) });
	const data = JSON.parse(health.value);
	if (health.status !== 200 || data.pid !== process.pid || data.service !== service)
		throw new Error('Diagnostic server identity check failed.');

	return baseUrl;
}

async function closeServer(server) {
	if (!server.listening) return;
	await new Promise((resolve) => {
		server.close(resolve);
		server.closeAllConnections();
	});
}

export function reportExitCode(report) {
	const results = report.models.flatMap((model) => model.checks);
	if (
		report.cancelled ||
		report.models.some((model) => Boolean(model.error) || Boolean(model.skipped)) ||
		results.some((result) => !['accepted', 'schema_rejected'].includes(result.status))
	)
		return 2;

	return results.some((result) => result.status === 'schema_rejected') ? 1 : 0;
}

export async function runCompatibility(config, { signal, timeoutMs = 120000, log = console.log } = {}) {
	let snapshot;
	try {
		snapshot = await readToolsSnapshot(config.cachePath);
	} catch {
		throw new Error(`Кэш схем отсутствует или повреждён. ${CACHE_HELP}`);
	}
	if (!Array.isArray(config.models) || config.models.length === 0) throw new Error('No models selected.');
	const checks = individualTools(snapshot.tools);
	const report = {
		version: 1,
		startedAt: new Date().toISOString(),
		completedAt: null,
		snapshot: {
			capturedAt: snapshot.capturedAt,
			sourceModel: snapshot.sourceModel,
			schemaHash: snapshot.schemaHash,
			...(snapshot.source ? { source: snapshot.source } : {})
		},
		cancelled: false,
		models: []
	};
	const reportPath = path.join(config.reportDirectory, `${report.startedAt.replace(/[:.]/g, '-')}-${randomUUID()}.json`);
	const keys = config.models.map((model) => model.apiKey).filter(Boolean);
	const sanitize = (text) => {
		let safe = String(text);
		for (const key of keys) safe = safe.replaceAll(key, '[REDACTED]');

		return safe.replace(/Bearer\s+[^\s"']+/gi, 'Bearer [REDACTED]').slice(0, 500);
	};
	log(`Снимок: ${snapshot.capturedAt} | ${snapshot.sourceModel} | ${checks.length} инструментов | SHA256 ${snapshot.schemaHash}`);
	log('Проверяется принятие схем, а не выполнение инструментов.');
	const hasExec = snapshot.tools.some((tool) => tool.type === 'custom' && tool.name === 'exec');
	report.snapshot.hasCustomExec = hasExec;
	log(
		hasExec
			? 'Custom exec присутствует в снимке; проверяется только принятие его схемы.'
			: 'Custom exec отсутствует в снимке — его поддержка этим тестом НЕ проверяется.'
	);
	log(`Отчёт: ${reportPath}`);
	await writeJsonAtomic(reportPath, report);
	try {
		for (const definition of config.models) {
			if (signal?.aborted) {
				report.cancelled = true;
				break;
			}
			const modelReport = { model: definition.model, displayName: definition.displayName, checks: [] };
			report.models.push(modelReport);
			log(`\n${definition.displayName} [${definition.model}]`);
			const servers = [];
			try {
				if (definition.error || !definition.apiKey) throw new Error(definition.error ?? 'Provider key is missing.');
				let upstreamBaseUrl = definition.upstreamBaseUrl;
				if (definition.bridgeUpstreamUrl) {
					const bridge = createBridgeServer({ upstreamUrl: definition.bridgeUpstreamUrl });
					servers.push(bridge);
					upstreamBaseUrl = await listenOwned(bridge, '/_bridge/health', 'cliproxy-namespace-bridge');
				}
				const router = createShellRouterServer({
					routes: [
						{
							clientModel: 'tool-compatibility',
							upstreamModel: definition.model,
							upstreamBaseUrl,
							apiKey: definition.apiKey,
							responsesAdapter: definition.responsesAdapter
						}
					]
				});
				servers.push(router);
				const baseUrl = await listenOwned(router, '/_shell-router/health', 'codex-model-shell-router');
				const allChecks = [
					{ name: '(контроль без инструментов)', tools: [] },
					...checks,
					{ name: '(весь набор)', tools: snapshot.tools }
				];
				for (const [index, check] of allChecks.entries()) {
					const result = await probeSchema(baseUrl, 'tool-compatibility', check.tools, { signal, timeoutMs });
					result.reason = sanitize(result.reason);
					modelReport.checks.push({ tool: check.name, ...result });
					log(
						`[${index + 1}/${allChecks.length}] ${check.name}: ${LABELS[result.status]} (${result.durationMs} мс) — ${result.reason}`
					);
					await writeJsonAtomic(reportPath, report);
					if (signal?.aborted) {
						report.cancelled = true;
						break;
					}
					if (index === 0 && result.status !== 'accepted') {
						modelReport.skipped = 'Control request failed; tool checks skipped.';
						log('Контрольный запрос не прошёл; проверки инструментов этой модели пропущены.');
						break;
					}
				}
			} catch (error) {
				modelReport.error = sanitize(errorMessage(error));
				log(`Ошибка: ${modelReport.error}`);
			} finally {
				for (const server of servers.reverse()) await closeServer(server);
			}
			await writeJsonAtomic(reportPath, report);
		}
	} finally {
		report.cancelled ||= Boolean(signal?.aborted);
		report.completedAt = new Date().toISOString();
		report.exitCode = reportExitCode(report);
		report.summary = {};
		for (const result of report.models.flatMap((model) => model.checks)) {
			report.summary[result.status] = (report.summary[result.status] ?? 0) + 1;
		}
		await writeJsonAtomic(reportPath, report);
	}
	for (const [status, count] of Object.entries(report.summary)) log(`${LABELS[status]}: ${count}`);
	log(`\nПроверка завершена. Код: ${report.exitCode}. Отчёт: ${reportPath}`);

	return { report, reportPath, exitCode: report.exitCode };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
	const controller = new AbortController();
	const cancel = () => controller.abort();
	process.once('SIGINT', cancel);
	process.once('SIGTERM', cancel);
	try {
		if (process.argv[2] === '--validate-cache') {
			try {
				const snapshot = await ensureToolsSnapshot(process.argv[3], process.argv[4]);
				if (snapshot.source?.kind === 'omniroute-log') {
					console.log(`Используется снимок из лога OmniRoute: ${snapshot.source.file} (${snapshot.capturedAt}).`);
				}
			} catch {
				throw new Error(`Кэш схем отсутствует или повреждён. ${CACHE_HELP}`);
			}
		} else {
			let input = '';
			for await (const chunk of process.stdin) {
				input += chunk;
				if (input.length > 1024 * 1024) throw new Error('Diagnostic configuration is too large.');
			}
			let config;
			try {
				config = JSON.parse(input);
			} catch {
				throw new Error('Invalid diagnostic configuration JSON.');
			}
			const result = await runCompatibility(config, { signal: controller.signal });
			process.exitCode = result.exitCode;
		}
	} catch (error) {
		console.error(errorMessage(error));
		process.exitCode = 2;
	} finally {
		process.removeListener('SIGINT', cancel);
		process.removeListener('SIGTERM', cancel);
	}
}
